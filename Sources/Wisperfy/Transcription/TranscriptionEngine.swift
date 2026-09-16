import AVFoundation
import Foundation

/// One revision of the running transcript. Non-final updates may be replaced wholesale.
struct TranscriptionUpdate: Sendable {
    let text: String
    let isFinal: Bool
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case localeUnsupported(String)
    case modelInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device speech recognition is not available on this Mac."
        case .localeUnsupported(let id): "Speech recognition does not support \(id)."
        case .modelInstallFailed(let why): "Speech model download failed: \(why)"
        }
    }
}

/// The seam between the dictation pipeline and a speech-to-text implementation.
///
/// Lifecycle per utterance: `preferredFormat` → `start` → many `feed` → `finish`.
/// `start` returns a stream of transcript revisions that ends after `finish` once the
/// engine has emitted its last final result.
protocol TranscriptionEngine: Sendable {
    /// The audio format the engine wants fed. Nil means "anything 16 kHz mono float".
    func preferredFormat() async -> AVAudioFormat?
    func start() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func feed(_ chunk: AudioChunk) async
    /// Stop feeding and produce the final transcript on the update stream.
    func finish() async
    /// Stop immediately and discard everything. The update stream ends without a final result.
    func cancel() async
}
