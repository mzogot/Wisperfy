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
        if let cachedSnapshot { return cachedSnapshot }
        let snapshot = VocabularySnapshot(entries: entries)
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Canonical terms, for recognizer hints and the polish prompt.
    var terms: [String] {
        entries.map(\.canonical).filter { !$0.isEmpty }
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try Self.decoder.decode([VocabularyEntry].self, from: data)
        } catch {
            Log.app.error("vocabulary: could not read \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let data: Data
        do {
            data = try Self.encoder.encode(entries)
        } catch {
            Log.app.error("vocabulary: encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            // Coalesce keystroke-by-keystroke edits from the Vocabulary window.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(data, to: url)
        }
        previous?.cancel()
    }

    private nonisolated static func write(_ data: Data, to url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("vocabulary: write failed: \(error.localizedDescription, privacy: .public)")
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
    /// variants win over their prefixes. Nil when there is nothing to match.
    let matcher: NSRegularExpression?
    /// Normalized matched text → entry, for looking up what a match belongs to.
    let lookup: [String: VocabularyEntry]

    init(entries: [VocabularyEntry]) {
        let entries = entries.filter { !$0.canonical.trimmingCharacters(in: .whitespaces).isEmpty }
        self.entries = entries
        terms = entries.map(\.canonical)

        var lookup: [String: VocabularyEntry] = [:]
        for entry in entries {
            for variant in [entry.canonical] + entry.variants {
                let key = Vocabulary.normalize(variant)
                guard !key.isEmpty, lookup[key] == nil else { continue }
                lookup[key] = entry
            }
        }
        self.lookup = lookup

        let alternatives = lookup.keys
            .sorted { $0.count > $1.count }
            .map { key in
                key.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"\s+"#)
            }
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
