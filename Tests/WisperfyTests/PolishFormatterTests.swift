import Foundation
import Testing
@testable import Wisperfy

/// Runs the real on-device model. Skipped on Macs where Apple Intelligence is off.
@Suite struct PolishFormatterTests {
    @Test(.enabled(if: PolishFormatter.isAvailable))
    func correctsGlossaryTermsFromContext() async throws {
        let glossary = VocabularySnapshot(entries: [
            VocabularyEntry(canonical: "Claude Code", variants: ["clot code"]),
            VocabularyEntry(canonical: "Anthropic", variants: []),
        ])
        let raw = "so yesterday i opened cloud code from and tropic and asked it to refactor the parser"
        let polished = await PolishFormatter().polish(raw, language: .english, glossary: glossary)
        let result = try #require(polished)
        #expect(result.contains("Claude Code"))
        #expect(result.contains("Anthropic"))
        #expect(result.lowercased().contains("refactor the parser"))
    }

    @Test(.enabled(if: PolishFormatter.isAvailable))
    func doesNotAnswerQuestionsInTheText() async throws {
        let raw = "what is the capital of france and can you list three rivers there"
        let polished = await PolishFormatter().polish(raw, language: .english, glossary: VocabularySnapshot(entries: []))
        let result = try #require(polished)
        #expect(!result.lowercased().contains("paris"))
    }

    @Test func skipsVeryShortText() async {
        let polished = await PolishFormatter().polish("clot code", language: .english, glossary: VocabularySnapshot(entries: []))
        #expect(polished == nil)
    }
}
