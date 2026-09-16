import Foundation

/// One replacement the vocabulary made in a transcript, kept with the history entry so
/// the user can see the dictionary working.
struct AppliedCorrection: Codable, Hashable, Sendable {
    let heard: String
    let written: String
}

/// Deterministic replacement of known misrecognitions with the user's spelling.
///
/// Matches are case-insensitive and bounded by non-letters, so "clot code" becomes
/// "Claude Code" but "clotted" is left alone. Glued and hyphenated forms of a variant
/// ("CloudCode", "Cloud-Code") match too. Longer variants win over shorter ones.
struct VocabularyFormatter: TextFormatter {
    /// What one pass did: the rewritten text, how often each entry fired, and every
    /// replacement in order of appearance.
    struct Application: Sendable {
        var text: String
        var hits: [VocabularyEntry.ID: Int]
        var corrections: [AppliedCorrection]
    }

    let snapshot: VocabularySnapshot

    func format(_ raw: String) -> String {
        apply(raw).text
    }

    func apply(_ raw: String) -> Application {
        guard let matcher = snapshot.matcher else { return Application(text: raw, hits: [:], corrections: []) }
        let ns = raw as NSString
        var output = ""
        var cursor = 0
        var hits: [VocabularyEntry.ID: Int] = [:]
        var corrections: [AppliedCorrection] = []

        for match in matcher.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: match.range)
            guard let entry = snapshot.lookup[Vocabulary.matchKey(matched)], matched != entry.canonical else { continue }
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += entry.canonical
            cursor = match.range.location + match.range.length
            hits[entry.id, default: 0] += 1
            corrections.append(AppliedCorrection(heard: matched, written: entry.canonical))
        }
        output += ns.substring(from: cursor)
        return Application(text: output, hits: hits, corrections: corrections)
    }
}
