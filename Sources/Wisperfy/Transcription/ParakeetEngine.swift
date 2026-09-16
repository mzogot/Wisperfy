import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio: CoreML on the Neural Engine, 25 languages
/// with automatic language detection, punctuation and capitalisation built in.
///
/// The model is not a streaming model. Audio is accumulated and transcribed in one pass
/// at the end, which at roughly 100× realtime is imperceptible for push-to-talk. For
/// live text during a hands-free session the whole buffer is re-transcribed every couple
/// of seconds; that stays cheap until the buffer is a few minutes long, after which live
/// updates pause and only the final pass runs.
actor ParakeetEngine: TranscriptionEngine {
    private static let sampleRate = 16_000
    private static let minimumSamples = 1_600            // 0.1 s; a stray tap is not speech
    private static let partialInterval: Duration = .seconds(2)
    private static let partialLimitSeconds = 180.0       // beyond this, wait for the final pass

    private let languageHint: Language?
    private var samples: [Float] = []
    private var emit: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?
    private var partials: Task<Void, Never>?
    private var samplesAtLastPartial = 0

    init(language: DictationLanguage) {
        switch language {
        case .english: languageHint = .english
        case .german: languageHint = .german
        case .russian: languageHint = .russian
        case .auto: languageHint = nil
        }
    }

    func preferredFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        samples.removeAll(keepingCapacity: true)
        samplesAtLastPartial = 0

        let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
        emit = continuation

        // Load (or download) up front so the user waits before speaking, not after.
        _ = try await ParakeetModelStore.shared.manager()

        partials = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.partialInterval)
                guard !Task.isCancelled, let self else { return }
                await self.emitPartial()
            }
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
        // AudioCapture already converted to the format `preferredFormat` asked for.
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
    }

    func finish() async {
        partials?.cancel()
        await partials?.value
        partials = nil

        defer {
            emit?.finish()
            emit = nil
            samples.removeAll(keepingCapacity: true)
        }

        guard samples.count >= Self.minimumSamples else {
            Log.speech.info("Parakeet: only \(self.samples.count, privacy: .public) samples, skipping")
            emit?.yield(TranscriptionUpdate(text: "", isFinal: true))
            return
        }

        do {
            let started = ContinuousClock.now
            let text = try await transcribe(samples)
            let elapsed = ContinuousClock.now - started
            let audioSeconds = Double(samples.count) / Double(Self.sampleRate)
            Log.speech.info("Parakeet: \(audioSeconds, format: .fixed(precision: 1))s audio in \(elapsed.inSeconds, format: .fixed(precision: 2))s")
            emit?.yield(TranscriptionUpdate(text: text, isFinal: true))
        } catch {
            Log.speech.error("Parakeet failed: \(error.localizedDescription, privacy: .public)")
            emit?.finish(throwing: error)
            emit = nil
        }
    }

    func cancel() async {
        partials?.cancel()
        partials = nil
        emit?.finish()
        emit = nil
        samples.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private func emitPartial() async {
        let count = samples.count
        guard count > samplesAtLastPartial + Self.sampleRate / 2,        // at least 0.5 s new audio
              Double(count) / Double(Self.sampleRate) <= Self.partialLimitSeconds
        else { return }
        samplesAtLastPartial = count
        do {
            let text = try await transcribe(Array(samples.prefix(count)))
            emit?.yield(TranscriptionUpdate(text: text, isFinal: false))
        } catch {
            Log.speech.error("Parakeet partial failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribe(_ audio: [Float]) async throws -> String {
        let manager = try await ParakeetModelStore.shared.manager()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state, language: languageHint)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Process-wide Parakeet model cache. Loading takes seconds from disk and a one-time
/// download of roughly 500 MB before that, so every utterance shares one instance.
actor ParakeetModelStore {
    static let shared = ParakeetModelStore()

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// True once the model files are on disk. Filesystem-based so the UI can show the
    /// "downloading" hint before anything is loaded.
    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    func manager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }

        let task = Task<AsrManager, Error> {
            let stage = Self.isDownloaded ? "loading from disk" : "downloading (one time)"
            Log.speech.info("Parakeet: \(stage, privacy: .public)")
            let started = ContinuousClock.now
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.speech.info("Parakeet: ready in \((ContinuousClock.now - started).inSeconds, format: .fixed(precision: 1))s")
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            self.manager = manager
            return manager
        } catch {
            loading = nil   // a transient download failure must not wedge the engine
            throw error
        }
    }
}
