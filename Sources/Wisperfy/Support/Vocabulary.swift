import Foundation
import Observation

/// One term the user wants spelled a particular way, plus the ways the recognizer has
/// misheard it. "Claude Code" with variants "clot code", "cloud code", "Клод код".
struct VocabularyEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// The spelling to produce.
    var canonical: String
    /// Misrecognitions that should become `canonical`. Matched case-insensitively on
    /// word boundaries, so keep single common words ("cloud") out of here.
    var variants: [String]
    /// How often a variant has been replaced. Lets the user see which mappings earn
    /// their keep.
    var hits: Int

    init(id: UUID = UUID(), canonical: String, variants: [String] = [], hits: Int = 0) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.hits = hits
    }

    /// The file is meant to be hand-editable, so only `canonical` is required. An entry
    /// typed as `{"canonical": "Vercel"}` gets an id and empty defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        canonical = try container.decode(String.self, forKey: .canonical)
        variants = try container.decodeIfPresent([String].self, forKey: .variants) ?? []
        hits = try container.decodeIfPresent(Int.self, forKey: .hits) ?? 0
    }
}

/// Something about an entry that will probably surprise the user: a variant that is an
/// ordinary word, or one that another entry already claims.
enum VocabularyWarning: Hashable, Sendable {
    /// A single-word variant the dictionary knows; every occurrence will be rewritten.
    case commonWord(variant: String)
    /// The same spelling is listed under another term; the first entry wins silently.
    case collision(text: String, other: String)

    var message: String {
        switch self {
        case .commonWord(let variant):
            "“\(variant)” is an ordinary word. Every “\(variant)” you say will be replaced."
        case .collision(let text, let other):
            "“\(text)” is also listed under “\(other)”. Only the first entry applies."
        }
    }
}

/// A word-level substitution extracted from a user correction, offered once before it
/// becomes a vocabulary entry.
struct CorrectionSuggestion: Identifiable, Hashable, Sendable {
    let id = UUID()
    let heard: String
    let meant: String
}

/// The user's vocabulary: canonical terms and their known misrecognitions, persisted
/// as JSON next to the history. It feeds three places:
/// - the Apple recognizer, which takes the canonical terms as contextual hints;
/// - `VocabularyFormatter`, which rewrites variants deterministically;
/// - `PolishFormatter`, which lists the glossary in its prompt.
///
/// Entries grow from corrections the user makes in the History window or the session
/// panel: each word-level substitution is offered once and, if accepted, becomes a
/// variant, so the next dictation benefits from the last one.
@MainActor
@Observable
final class Vocabulary {
    private(set) var entries: [VocabularyEntry] = []

    /// Compiled once per change; every utterance reuses it.
    @ObservationIgnored private var cachedSnapshot: VocabularySnapshot?

    private let fileURL: URL
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    /// Modification date of the file as we last read or wrote it.
    @ObservationIgnored private var knownModificationDate: Date?
    /// Set when the file exists but could not be decoded. While it is set nothing is
    /// written, so a typo in a hand-edited file never costs the user their list.
    private(set) var loadError: String?

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "Wisperfy", directoryHint: .isDirectory)
        fileURL = base.appending(path: "vocabulary.json")
        load()
    }

    // MARK: - Reading

    /// Immutable view for the formatters and the recognizer; safe to hand across actors.
    func snapshot() -> VocabularySnapshot {
        reloadIfChanged()
        if let cachedSnapshot { return cachedSnapshot }
        let snapshot = VocabularySnapshot(entries: entries)
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Canonical terms, for the polish prompt.
    var terms: [String] {
        entries.map(\.canonical).filter { !$0.isEmpty }
    }

    /// Recognizer hints are a nudge, and a long list makes the model drift and invent
    /// text on quiet audio. Terms that have fired most come first, then the newest.
    static let maximumHintTerms = 50

    var hintTerms: [String] {
        entries.enumerated()
            .filter { !$0.element.canonical.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.hits != rhs.element.hits { return lhs.element.hits > rhs.element.hits }
                return lhs.offset > rhs.offset
            }
            .prefix(Self.maximumHintTerms)
            .map(\.element.canonical)
    }

    /// What might go wrong with an entry as it stands. `isCommonWord` is the dictionary
    /// check (the spell checker in the app, anything in tests); it is only asked about
    /// single-word variants, since a multi-word pattern has to match in full.
    func warnings(for entry: VocabularyEntry, isCommonWord: (String) -> Bool) -> [VocabularyWarning] {
        var warnings: [VocabularyWarning] = []
        for variant in entry.variants {
            let key = Self.matchKey(variant)
            guard !key.isEmpty else { continue }
            if !variant.contains(where: { $0.isWhitespace || $0 == "-" }), isCommonWord(variant) {
                warnings.append(.commonWord(variant: variant))
            }
        }
        for other in entries where other.id != entry.id {
            let claimed = ([other.canonical] + other.variants).map(Self.matchKey)
            for text in [entry.canonical] + entry.variants {
                let key = Self.matchKey(text)
                guard !key.isEmpty, claimed.contains(key) else { continue }
                warnings.append(.collision(text: text, other: other.canonical))
            }
        }
        var seen = Set<VocabularyWarning>()
        return warnings.filter { seen.insert($0).inserted }
    }

    /// Picks up edits made to the file outside the app. Cheap (one stat), so it runs
    /// before every utterance and whenever the Vocabulary window opens. Skipped while
    /// our own write is pending, since the file would otherwise win over unsaved typing.
    func reloadIfChanged() {
        guard pendingWrite == nil else { return }
        let current = Self.modificationDate(of: fileURL)
        guard current != knownModificationDate else { return }
        load()
        cachedSnapshot = nil
        Log.app.info("vocabulary: reloaded after external change")
    }

    func entry(matching canonical: String) -> VocabularyEntry? {
        let wanted = Self.normalize(canonical)
        return entries.first { Self.normalize($0.canonical) == wanted }
    }

    // MARK: - Editing

    @discardableResult
    func add(canonical: String, variants: [String] = []) -> VocabularyEntry {
        let entry = VocabularyEntry(canonical: canonical.trimmingCharacters(in: .whitespaces), variants: variants.map(Self.normalize))
        entries.append(entry)
        changed()
        Log.app.info("vocabulary: added term")
        return entry
    }

    func update(_ id: VocabularyEntry.ID, canonical: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].canonical = canonical
        changed()
    }

    func update(_ id: VocabularyEntry.ID, variants: [String]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        entries[index].variants = variants.map(Self.normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
        changed()
    }

    func remove(_ id: VocabularyEntry.ID) {
        entries.removeAll { $0.id == id }
        changed()
    }

    /// Bumps hit counts after a formatting pass. Persisted lazily with everything else.
    func recordHits(_ counts: [VocabularyEntry.ID: Int]) {
        guard !counts.isEmpty else { return }
        for (id, count) in counts {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            entries[index].hits += count
        }
        cachedSnapshot = nil
        save()
    }

    // MARK: - Learning from corrections

    /// Word-level substitutions between what was transcribed and what the user changed
    /// it to, minus anything the vocabulary already knows. Case-only and
    /// punctuation-only edits are ignored; they are formatting, not vocabulary.
    func suggestions(original: String, corrected: String) -> [CorrectionSuggestion] {
        let known = Set(entries.flatMap { [$0.canonical] + $0.variants }.map(Self.normalize))
        var seen = Set<String>()
        return WordDiff.substitutions(from: original, to: corrected)
            .filter { pair in
                let heard = Self.normalize(pair.heard)
                let meant = Self.normalize(pair.meant)
                guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return false }
                guard !known.contains(heard) else { return false }
                return seen.insert(heard).inserted
            }
            .prefix(WordDiff.maximumSuggestions)
            .map { CorrectionSuggestion(heard: $0.heard, meant: $0.meant) }
    }

    /// Turns an accepted suggestion into a variant of an existing term, or a new term.
    func accept(_ suggestion: CorrectionSuggestion) {
        let heard = Self.normalize(suggestion.heard)
        if let existing = entry(matching: suggestion.meant) {
            update(existing.id, variants: existing.variants + [heard])
        } else {
            add(canonical: suggestion.meant, variants: [heard])
        }
        Log.app.info("vocabulary: learned a correction")
    }

    // MARK: - Helpers

    /// `normalize` with the separators between words removed, so "cloud code",
    /// "Cloud-Code" and "CloudCode" are the same key.
    nonisolated static func matchKey(_ text: String) -> String {
        normalize(text).filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Lowercased, single-spaced, without surrounding punctuation.
    nonisolated static func normalize(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            .lowercased()
    }

    private func changed() {
        cachedSnapshot = nil
        save()
    }

    // MARK: - Persistence

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private func load() {
        knownModificationDate = Self.modificationDate(of: fileURL)
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            loadError = nil
            return
        }
        do {
            entries = try Self.decoder.decode([VocabularyEntry].self, from: data)
            loadError = nil
        } catch {
            entries = []
            loadError = Self.describe(error)
            Log.app.error("vocabulary: could not read \(self.fileURL.lastPathComponent, privacy: .public): \(self.loadError ?? "", privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(context.debugDescription) at \(path(context))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map { key in
            key.intValue.map { "entry \($0 + 1)" } ?? key.stringValue
        }
        return parts.isEmpty ? "top level" : parts.joined(separator: " › ")
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func save() {
        if let loadError {
            Log.app.error("vocabulary: not saving over an unreadable file (\(loadError, privacy: .public))")
            return
        }
        let data: Data
        do {
            data = try Self.encoder.encode(entries)
        } catch {
            Log.app.error("vocabulary: encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            // Coalesce keystroke-by-keystroke edits from the Vocabulary window.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let written = await Self.write(data, to: url)
            guard let self, !Task.isCancelled else { return }
            if let written { self.knownModificationDate = written }
            self.pendingWrite = nil
        }
        previous?.cancel()
    }

    /// Returns the file's modification date after the write, so a reload does not
    /// mistake our own save for an outside edit.
    private nonisolated static func write(_ data: Data, to url: URL) async -> Date? {
        do {
            try PrivateFile.write(data, to: url)
            return modificationDate(of: url)
        } catch {
            Log.app.error("vocabulary: write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// A frozen copy of the vocabulary with its matcher compiled. Value type, so it can be
/// captured by formatters running off the main actor.
struct VocabularySnapshot: Sendable {
    let entries: [VocabularyEntry]
    /// Canonical terms in a stable order.
    let terms: [String]
    /// One alternation over every variant and canonical, longest first so multi-word
    /// variants win over their prefixes. Between the words of a variant any run of
    /// whitespace or hyphens is accepted, including none, so "cloud code" also catches
    /// "CloudCode" and "Cloud-Code". The whole pattern still has to match on word
    /// boundaries: "Cloudflare" and a bare "cloud" are untouched. Nil when empty.
    let matcher: NSRegularExpression?
    /// `Vocabulary.matchKey` of the matched text → entry.
    let lookup: [String: VocabularyEntry]

    init(entries: [VocabularyEntry]) {
        let entries = entries.filter { !$0.canonical.trimmingCharacters(in: .whitespaces).isEmpty }
        self.entries = entries
        terms = entries.map(\.canonical)

        // Keyed without separators, so the glued and hyphenated forms the recognizer
        // produces ("CloudCode", "Cloud-Code") resolve to the same entry as "cloud code".
        var lookup: [String: VocabularyEntry] = [:]
        var patterns: [String: String] = [:]
        for entry in entries {
            for variant in [entry.canonical] + entry.variants {
                let key = Vocabulary.matchKey(variant)
                guard !key.isEmpty, lookup[key] == nil else { continue }
                lookup[key] = entry
                let parts = Vocabulary.normalize(variant)
                    .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                patterns[key] = parts.joined(separator: #"[\s\-]*"#)
            }
        }
        self.lookup = lookup

        let alternatives = patterns
            .sorted { $0.key.count > $1.key.count }
            .map(\.value)
        if alternatives.isEmpty {
            matcher = nil
        } else {
            let pattern = #"(?i)(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
            matcher = try? NSRegularExpression(pattern: pattern)
        }
    }
}

/// Word-level diff between a transcript and its corrected version.
enum WordDiff {
    /// Longest phrase (in words) on either side of a substitution worth learning.
    static let maximumPhraseWords = 4
    static let maximumSuggestions = 5

    struct Substitution: Hashable, Sendable {
        let heard: String
        let meant: String
    }

    /// Contiguous runs where words were replaced. Pure insertions and deletions are
    /// skipped: they are edits to the content, not evidence of a misrecognition.
    static func substitutions(from original: String, to corrected: String) -> [Substitution] {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        let difference = after.difference(from: before)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Kept words pair up in order on both sides, so the runs of removed and
        // inserted words between two kept words belong together.
        var result: [Substitution] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            let iRemoved = i < before.count && removed.contains(i)
            let jInserted = j < after.count && inserted.contains(j)
            guard iRemoved || jInserted else {
                i += 1
                j += 1
                continue
            }
            let iStart = i
            while i < before.count, removed.contains(i) { i += 1 }
            let jStart = j
            while j < after.count, inserted.contains(j) { j += 1 }

            let heard = before[iStart..<i]
            let meant = after[jStart..<j]
            guard !heard.isEmpty, !meant.isEmpty,
                  heard.count <= maximumPhraseWords, meant.count <= maximumPhraseWords
            else { continue }
            result.append(Substitution(
                heard: strip(heard.joined(separator: " ")),
                meant: strip(meant.joined(separator: " "))
            ))
        }
        return result
    }

    /// Surrounding punctuation belongs to the sentence, not the term.
    private static func strip(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
