import Foundation

/// Deterministic replacement of known misrecognitions with the user's spelling.
///
/// Matches are case-insensitive and bounded by non-letters, so "clot code" becomes
/// "Claude Code" but "clotted" is left alone. Longer variants win over shorter ones.
struct VocabularyFormatter: TextFormatter {
    let snapshot: VocabularySnapshot

    func format(_ raw: String) -> String {
        apply(raw).text
    }

    /// The rewritten text plus how often each entry fired, for the hit counters.
    func apply(_ raw: String) -> (text: String, hits: [VocabularyEntry.ID: Int]) {
        guard let matcher = snapshot.matcher else { return (raw, [:]) }
        let ns = raw as NSString
        var output = ""
        var cursor = 0
        var hits: [VocabularyEntry.ID: Int] = [:]

        for match in matcher.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: match.range)
            guard let entry = snapshot.lookup[Vocabulary.normalize(matched)], matched != entry.canonical else { continue }
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += entry.canonical
            cursor = match.range.location + match.range.length
            hits[entry.id, default: 0] += 1
        }
        output += ns.substring(from: cursor)
        return (output, hits)
    }
}
