import Foundation

/// The seam between raw transcript and what gets typed. `FormattingPipeline` chains the
/// tiers: rules, vocabulary, then the on-device language model.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Deterministic cleanup: filler words, whitespace, punctuation spacing, sentence case.
struct RuleBasedFormatter: TextFormatter {
    /// Only tokens that are never real words, in English, German and Russian. "like",
    /// "also" and "ну" are left alone on purpose: they are words as often as fillers.
    /// Cyrillic "мм" is safe to strip; Latin "mm" is not (millimetres), so it is excluded.
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}'])(?:u+m+|u+h+m*|er+m+|hmm+|mm+hmm|äh+m*|öh+m*|hm+|э+м*|э-э|мм+)(?![\p{L}'])[,.]?\s*"#
    )
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.!?;:])"#)
    private static let repeatedPunctuation = try! NSRegularExpression(pattern: #"([,.!?;:])(?:\s*\1)+"#)
    private static let whitespaceRuns = try! NSRegularExpression(pattern: #"[ \t]+"#)
    private static let sentenceStarts = try! NSRegularExpression(pattern: #"(^|[.!?]\s+)(\p{Ll})"#)

    func format(_ raw: String) -> String {
        var text = raw
        text = Self.fillers.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "")
        text = Self.whitespaceRuns.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: " ")
        text = Self.spaceBeforePunctuation.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "$1")
        text = Self.repeatedPunctuation.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "$1")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        text = text.trimmingCharacters(in: .whitespaces)
        text = capitalizeSentences(text)

        if let last = text.last, last.isLetter || last.isNumber {
            text.append(".")
        }
        return text
    }

    private func capitalizeSentences(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        let matches = Self.sentenceStarts.matches(in: text, range: text.fullRange)
        for match in matches.reversed() {
            let range = match.range(at: 2)
            let upper = ns.substring(with: range).uppercased()
            ns.replaceCharacters(in: range, with: upper)
        }
        return ns as String
    }
}

private extension String {
    var fullRange: NSRange { NSRange(startIndex..., in: self) }
}
