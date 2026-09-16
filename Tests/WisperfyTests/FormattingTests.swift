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
        let result = formatter.apply("I opened clot code, then Cloud   Code again. Clotted cream.")
        #expect(result.text == "I opened Claude Code, then Claude Code again. Clotted cream.")
        #expect(result.hits.values.reduce(0, +) == 2)
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

@Suite struct GluedVariantTests {
    let snapshot = VocabularySnapshot(entries: [
        VocabularyEntry(canonical: "Claude Code", variants: ["cloud code"]),
        VocabularyEntry(canonical: "Vibe Coding", variants: ["wipe coding"]),
    ])

    @Test func matchesGluedAndHyphenatedForms() {
        let formatter = VocabularyFormatter(snapshot: snapshot)
        #expect(formatter.format("CloudCode, Cloud-Code, cloud  code and claudecode") == "Claude Code, Claude Code, Claude Code and Claude Code")
        #expect(formatter.format("try wipecoding") == "try Vibe Coding")
    }

    @Test func requiresTheWholePattern() {
        let formatter = VocabularyFormatter(snapshot: snapshot)
        #expect(formatter.format("Cloudflare in the cloud, cloud coder") == "Cloudflare in the cloud, cloud coder")
    }

    @Test func reportsWhatItChanged() {
        let result = VocabularyFormatter(snapshot: snapshot).apply("open cloud-code and CloudCode, then Claude Code")
        #expect(result.corrections == [
            AppliedCorrection(heard: "cloud-code", written: "Claude Code"),
            AppliedCorrection(heard: "CloudCode", written: "Claude Code"),
        ])
        #expect(result.hits.values.reduce(0, +) == 2)
    }
}

@Suite @MainActor struct VocabularyFileTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "WisperfyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func write(_ json: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(to: directory.appending(path: "vocabulary.json"), atomically: true, encoding: .utf8)
    }

    @Test func handWrittenEntriesNeedOnlyACanonical() throws {
        let directory = makeDirectory()
        try write(#"[{"canonical": "Vercel"}, {"canonical": "Supabase", "variants": ["super base"]}]"#, in: directory)
        let vocabulary = Vocabulary(directory: directory)
        #expect(vocabulary.loadError == nil)
        #expect(vocabulary.entries.map(\.canonical) == ["Vercel", "Supabase"])
        #expect(vocabulary.entries[1].variants == ["super base"])
        #expect(vocabulary.entries[1].hits == 0)
    }

    @Test func brokenFileIsNeverOverwritten() async throws {
        let directory = makeDirectory()
        let broken = #"[{"canonical": "Vercel"}, {"canonical": 5}]"#
        try write(broken, in: directory)
        let vocabulary = Vocabulary(directory: directory)
        #expect(vocabulary.loadError != nil)
        #expect(vocabulary.entries.isEmpty)
        vocabulary.add(canonical: "Anthropic")
        try await Task.sleep(for: .milliseconds(600))
        let onDisk = try String(contentsOf: directory.appending(path: "vocabulary.json"), encoding: .utf8)
        #expect(onDisk == broken)
    }

    @Test func picksUpExternalEdits() async throws {
        let directory = makeDirectory()
        try write(#"[{"canonical": "Vercel"}]"#, in: directory)
        let vocabulary = Vocabulary(directory: directory)
        #expect(vocabulary.snapshot().terms == ["Vercel"])
        // Modification dates have one-second resolution on some file systems.
        try await Task.sleep(for: .seconds(1.1))
        try write(#"[{"canonical": "Vercel"}, {"canonical": "Anthropic"}]"#, in: directory)
        #expect(vocabulary.snapshot().terms == ["Vercel", "Anthropic"])
    }

    @Test func hintTermsAreRankedAndCapped() {
        let vocabulary = Vocabulary(directory: makeDirectory())
        for index in 0..<(Vocabulary.maximumHintTerms + 5) {
            vocabulary.add(canonical: "Term \(index)")
        }
        let popular = vocabulary.entries[3]
        vocabulary.recordHits([popular.id: 7])
        let hints = vocabulary.hintTerms
        #expect(hints.count == Vocabulary.maximumHintTerms)
        #expect(hints.first == "Term 3")
        #expect(hints[1] == "Term \(Vocabulary.maximumHintTerms + 4)")
        #expect(!hints.contains("Term 0"))
    }
}

@Suite @MainActor struct VocabularyWarningTests {
    private func makeVocabulary() -> Vocabulary {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WisperfyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Vocabulary(directory: directory)
    }

    @Test func flagsCommonSingleWordVariants() {
        let vocabulary = makeVocabulary()
        let entry = vocabulary.add(canonical: "Claude Code", variants: ["cloud", "cloud code", "clot code"])
        let warnings = vocabulary.warnings(for: entry) { ["cloud", "code"].contains($0) }
        #expect(warnings == [.commonWord(variant: "cloud")])
    }

    @Test func flagsCollisionsBetweenEntries() {
        let vocabulary = makeVocabulary()
        vocabulary.add(canonical: "Claude", variants: ["clot"])
        let entry = vocabulary.add(canonical: "Clot", variants: ["Claude Code"])
        let warnings = vocabulary.warnings(for: entry) { _ in false }
        #expect(warnings == [.collision(text: "Clot", other: "Claude")])
    }
}
