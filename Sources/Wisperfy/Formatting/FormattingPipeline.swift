import Foundation

/// The formatter the controller actually runs: rules, then vocabulary, then the
/// on-device language model when enabled, then vocabulary once more in case the model
/// undid a mapping. Each tier is optional in effect; the text always comes out.
@MainActor
final class FormattingPipeline: TextFormatter {
    /// The finished text plus what the vocabulary changed on the way, for history.
    struct Output: Sendable {
        var text: String
        var corrections: [AppliedCorrection]
    }

    private let rules = RuleBasedFormatter()
    private let polish = PolishFormatter()
    private let vocabulary: Vocabulary

    init(vocabulary: Vocabulary) {
        self.vocabulary = vocabulary
    }

    /// Call when dictation starts so the model is loaded by the time it is needed.
    func prepare() {
        guard Settings.shared.polish else { return }
        Task { await polish.prewarm() }
    }

    func format(_ raw: String) async -> String {
        await run(raw).text
    }

    func run(_ raw: String) async -> Output {
        var text = rules.format(raw)
        guard !text.isEmpty else { return Output(text: text, corrections: []) }

        let snapshot = vocabulary.snapshot()
        let mapper = VocabularyFormatter(snapshot: snapshot)
        var pass = mapper.apply(text)
        text = pass.text
        var hits = pass.hits
        var corrections = pass.corrections

        if Settings.shared.polish, PolishFormatter.isAvailable {
            let language = Settings.shared.language
            if let polished = await polish.polish(text, language: language, glossary: snapshot) {
                pass = mapper.apply(polished)
                text = rules.format(pass.text)
                hits.merge(pass.hits, uniquingKeysWith: +)
                corrections += pass.corrections
            }
        }

        vocabulary.recordHits(hits)
        var seen = Set<AppliedCorrection>()
        return Output(text: text, corrections: corrections.filter { seen.insert($0).inserted })
    }
}
