import Foundation
import Testing
@testable import Wisperfy

@Suite struct RuleBasedFormatterTests {
    let formatter = RuleBasedFormatter()

    @Test func stripsFillersAndCapitalises() {
        #expect(formatter.format("um so i think , we should ship") == "So i think, we should ship.")
    }

    @Test func leavesRealWordsAlone() {
        #expect(formatter.format("the box is 10 mm wide") == "The box is 10 mm wide.")
    }
}

@Suite struct VocabularyFormatterTests {
    let snapshot = VocabularySnapshot(entries: [
        VocabularyEntry(canonical: "Claude Code", variants: ["clot code", "cloud code", "Клод код"]),
        VocabularyEntry(canonical: "Anthropic", variants: ["and tropic", "entropic"]),
        VocabularyEntry(canonical: "Wisperfy", variants: ["whisper fi"]),
    ])

    @Test func replacesVariantsOnWordBoundaries() {
        let formatter = VocabularyFormatter(snapshot: snapshot)
        let (text, hits) = formatter.apply("I opened clot code, then Cloud   Code again. Clotted cream.")
        #expect(text == "I opened Claude Code, then Claude Code again. Clotted cream.")
        #expect(hits.values.reduce(0, +) == 2)
    }

    @Test func fixesCasingOfCanonicalTerm() {
        let formatter = VocabularyFormatter(snapshot: snapshot)
        #expect(formatter.format("ask anthropic about wisperfy") == "ask Anthropic about Wisperfy")
    }

    @Test func handlesCyrillicVariants() {
        let formatter = VocabularyFormatter(snapshot: snapshot)
        #expect(formatter.format("Я открыл клод код сегодня") == "Я открыл Claude Code сегодня")
    }

    @Test func longerVariantWinsOverPrefix() {
        let snapshot = VocabularySnapshot(entries: [
            VocabularyEntry(canonical: "Claude", variants: ["clot"]),
            VocabularyEntry(canonical: "Claude Code", variants: ["clot code"]),
        ])
        #expect(VocabularyFormatter(snapshot: snapshot).format("use clot code") == "use Claude Code")
    }

    @Test func emptyVocabularyIsIdentity() {
        let formatter = VocabularyFormatter(snapshot: VocabularySnapshot(entries: []))
        #expect(formatter.format("unchanged text") == "unchanged text")
    }
}

@Suite struct WordDiffTests {
    @Test func findsSubstitutions() {
        let pairs = WordDiff.substitutions(
            from: "I opened clot code and asked and tropic for help.",
            to: "I opened Claude Code and asked Anthropic for help."
        )
        #expect(pairs == [
            WordDiff.Substitution(heard: "clot code", meant: "Claude Code"),
            WordDiff.Substitution(heard: "and tropic", meant: "Anthropic"),
        ])
    }

    @Test func ignoresPureInsertionsAndDeletions() {
        #expect(WordDiff.substitutions(from: "one two three", to: "one two three four").isEmpty)
        #expect(WordDiff.substitutions(from: "one two three", to: "one three").isEmpty)
    }

    @Test func skipsLongRewrites() {
        let pairs = WordDiff.substitutions(
            from: "a b c d e f g",
            to: "h i j k l m n"
        )
        #expect(pairs.isEmpty)
    }

    @Test func stripsSentencePunctuation() {
        let pairs = WordDiff.substitutions(from: "Open clot code.", to: "Open Claude Code.")
        #expect(pairs == [WordDiff.Substitution(heard: "clot code", meant: "Claude Code")])
    }
}

@Suite @MainActor struct VocabularyLearningTests {
    private func makeVocabulary() -> Vocabulary {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WisperfyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Vocabulary(directory: directory)
    }

    @Test func suggestsUnknownSubstitutionsOnly() {
        let vocabulary = makeVocabulary()
        vocabulary.add(canonical: "Anthropic", variants: ["and tropic"])
        let suggestions = vocabulary.suggestions(
            original: "clot code by and tropic, in the Cloud.",
            corrected: "Claude Code by Anthropic, in the cloud."
        )
        #expect(suggestions.map(\.heard) == ["clot code"])
        #expect(suggestions.map(\.meant) == ["Claude Code"])
    }

    @Test func acceptingAddsVariantToExistingTerm() {
        let vocabulary = makeVocabulary()
        vocabulary.add(canonical: "Claude Code", variants: ["clot code"])
        vocabulary.accept(CorrectionSuggestion(heard: "Cloud Code", meant: "claude code"))
        #expect(vocabulary.entries.count == 1)
        #expect(vocabulary.entries[0].variants == ["clot code", "cloud code"])
    }

    @Test func acceptingCreatesNewTerm() {
        let vocabulary = makeVocabulary()
        vocabulary.accept(CorrectionSuggestion(heard: "whisper fi", meant: "Wisperfy"))
        #expect(vocabulary.entries.map(\.canonical) == ["Wisperfy"])
        #expect(vocabulary.snapshot().terms == ["Wisperfy"])
    }
}
