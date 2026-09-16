import Foundation
import Observation

/// One finished dictation. Empty transcripts are never recorded.
struct TranscriptEntry: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case pushToTalk
        case session

        var label: String {
            switch self {
            case .pushToTalk: "Push to talk"
            case .session: "Session"
            }
        }
    }

    let id: UUID
    let date: Date
    let text: String
    let source: Source
    /// `DictationLanguage.rawValue` at the time of dictation.
    let language: String
    /// Seconds of audio captured, for the history list.
    let seconds: Double
}

/// Every transcript the app has produced, newest first, persisted as JSON in
/// Application Support. Observable so the History window updates live.
///
/// The file is small (a few hundred short texts at most) so it is rewritten whole on
/// every change. Writes are chained so they land in order even when two utterances
/// finish back to back.
@MainActor
@Observable
final class TranscriptHistory {
    private(set) var entries: [TranscriptEntry] = []

    /// Oldest entries are dropped past this many. Keeps the file and the list bounded.
    private static let limit = 500

    private let fileURL: URL
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "Wisperfy", directoryHint: .isDirectory)
        fileURL = base.appending(path: "history.json")
        load()
    }

    @discardableResult
    func add(text: String, source: TranscriptEntry.Source, language: DictationLanguage, seconds: Double) -> TranscriptEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = TranscriptEntry(
            id: UUID(),
            date: .now,
            text: trimmed,
            source: source,
            language: language.rawValue,
            seconds: seconds
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        Log.app.info("history: added entry (\(trimmed.count, privacy: .public) chars, \(self.entries.count, privacy: .public) total)")
        return entry
    }

    /// Replaces the text of an entry the user edited. Everything else about it stays.
    func update(_ id: TranscriptEntry.ID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entries[index].text else { return }
        let old = entries[index]
        entries[index] = TranscriptEntry(
            id: old.id, date: old.date, text: trimmed, source: old.source,
            language: old.language, seconds: old.seconds
        )
        save()
        Log.app.info("history: edited entry")
    }

    func remove(_ id: TranscriptEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
        Log.app.info("history: cleared")
    }

    // MARK: - Persistence

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try Self.decoder.decode([TranscriptEntry].self, from: data)
                .sorted { $0.date > $1.date }
        } catch {
            Log.app.error("history: could not read \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let data: Data
        do {
            data = try Self.encoder.encode(entries)
        } catch {
            Log.app.error("history: encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            await Self.write(data, to: url)
        }
    }

    /// Runs off the main actor: a nonisolated async function executes on the global pool.
    private nonisolated static func write(_ data: Data, to url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("history: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
