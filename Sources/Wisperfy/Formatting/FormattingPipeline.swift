import Foundation

/// The formatter the controller actually runs: rules, then vocabulary, then the
/// on-device language model when enabled, then vocabulary once more in case the model
/// undid a mapping. Each tier is optional in effect; the text always comes out.
@MainActor
final class FormattingPipeline: TextFormatter {
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
        var text = rules.format(raw)
        guard !text.isEmpty else { return text }

        let snapshot = vocabulary.snapshot()
        let mapper = VocabularyFormatter(snapshot: snapshot)
        var (mapped, hits) = mapper.apply(text)
        text = mapped

        if Settings.shared.polish, PolishFormatter.isAvailable {
            let language = Settings.shared.language
            if let polished = await polish.polish(text, language: language, glossary: snapshot) {
                (mapped, _) = mapper.apply(polished)
                text = rules.format(mapped)
            }
        }

        vocabulary.recordHits(hits)
        return text
    }
}
