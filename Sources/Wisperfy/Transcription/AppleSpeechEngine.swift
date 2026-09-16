import AVFoundation
import Foundation
import Speech

/// Streaming on-device transcription using macOS 26's `SpeechAnalyzer` and `SpeechTranscriber`.
///
/// No model ships with the app. The OS downloads and manages the assets, so the very
/// first run for a locale may pause while `AssetInstallationRequest` completes.
actor AppleSpeechEngine: TranscriptionEngine {
    private static let finalizeTimeout = 4.0

    private let requestedLocale: Locale
    /// Vocabulary terms the recognizer should prefer, e.g. product names.
    private let contextualStrings: [String]

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var drain: Task<Void, Never>?

    /// Text the engine has committed. Volatile text is layered on top for display only.
    private var committed = ""

    init(locale: Locale, contextualStrings: [String] = []) {
        requestedLocale = locale
        self.contextualStrings = contextualStrings
    }

    func preferredFormat() async -> AVAudioFormat? {
        let module = transcriber ?? Self.makeTranscriber(locale: requestedLocale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }

        // `supportedLocale(equivalentTo:)` happily returns a locale the engine cannot
        // actually run (it did for ru-RU), so check against the real supported list.
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = requestedLocale.identifier(.bcp47)
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == wanted })
            ?? supported.first(where: { $0.language.languageCode == requestedLocale.language.languageCode })
        else {
            throw TranscriptionError.localeUnsupported(requestedLocale.identifier)
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        try await Self.ensureAssets(for: transcriber)

        let (audio, audioContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await applyContext(to: analyzer)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = audioContinuation
        committed = ""

        let (updates, emit) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()

        drain = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let text = await self.absorb(result)
                    emit.yield(TranscriptionUpdate(text: text, isFinal: false))
                }
                let final = await self?.committed ?? ""
                emit.yield(TranscriptionUpdate(text: final, isFinal: true))
                emit.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription, privacy: .public)")
                emit.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: audio)
        Log.speech.info("analyzer started for \(locale.identifier, privacy: .public)")
        return updates
    }

    func feed(_ chunk: AudioChunk) async {
        input?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        input?.finish()
        input = nil

        if let analyzer {
            // Finalize has been observed to never return when it received almost no
            // audio, so it is bounded. On timeout the analyzer is told to stop right now.
            let finished = await awaitWithTimeout(Self.finalizeTimeout) {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Log.speech.error("finalize failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !finished {
                Log.speech.error("finalize timed out after \(Self.finalizeTimeout, privacy: .public)s; cancelling")
                await awaitWithTimeout(1) { await analyzer.cancelAndFinishNow() }
            }
        }

        analyzer = nil
        transcriber = nil
        drain = nil
    }

    func cancel() async {
        input?.finish()
        input = nil
        drain?.cancel()
        if let analyzer {
            await awaitWithTimeout(1) { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        drain = nil
    }

    /// Whether Apple's engine can run this locale at all, without starting anything.
    static func supports(_ identifier: String) async -> Bool {
        let wanted = Locale(identifier: identifier)
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.language.languageCode == wanted.language.languageCode }
    }

    // MARK: - Helpers

    /// Biases recognition towards the user's vocabulary. A failure here is logged and
    /// ignored: the deterministic mapping still runs on the result.
    private func applyContext(to analyzer: SpeechAnalyzer) async {
        guard !contextualStrings.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings = [.general: contextualStrings]
        do {
            try await analyzer.setContext(context)
            Log.speech.info("context set with \(self.contextualStrings.count, privacy: .public) terms")
        } catch {
            Log.speech.error("setContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Folds one result in and returns the full text to show right now.
    private func absorb(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        if result.isFinal {
            committed += text
            return committed.trimmingCharacters(in: .whitespaces)
        }
        return (committed + text).trimmingCharacters(in: .whitespaces)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],   // live text while still talking
            attributeOptions: []
        )
    }

    private static func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let needed = transcriber.selectedLocales
        let ready = needed.allSatisfy { wanted in
            installed.contains { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }
        }
        if ready { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
