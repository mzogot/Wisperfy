import AVFoundation
import Accelerate
import Foundation

/// A PCM buffer the capture layer owns outright. Safe to send across isolation only
/// because `AudioCapture` always allocates fresh storage before handing one out.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .converterUnavailable: "The microphone format cannot be converted for the speech engine."
        }
    }
}

/// Microphone capture with on-the-fly conversion to the speech engine's format.
///
/// The tap callback runs on a real-time audio thread. Everything it touches lives in
/// `Pipeline`, which is only ever used from that thread while capture is running.
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var isRunning = false

    /// Starts capture and returns an *ordered* stream of converted buffers.
    ///
    /// - Parameter onLevel: Called on the audio thread with a 0…1 loudness value.
    func start(
        format: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw AudioCaptureError.noInputDevice }

        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let converter: AVAudioConverter?
        if native == format {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: native, to: format) else {
                throw AudioCaptureError.converterUnavailable
            }
            converter = made
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        let pipeline = Pipeline(
            converter: converter,
            targetFormat: format,
            continuation: continuation,
            onLevel: onLevel
        )

        input.removeTap(onBus: 0)
        // @Sendable is load-bearing: without it Swift infers this closure as main-actor
        // isolated (it is formed inside a @MainActor method) and inserts a runtime
        // isolation check that traps on the real-time audio thread.
        input.installTap(onBus: 0, bufferSize: 2048, format: native) { @Sendable buffer, _ in
            pipeline.process(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("capture started: \(native.sampleRate, privacy: .public) Hz → \(format.sampleRate, privacy: .public) Hz")
        return stream
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRunning = false
        Log.audio.info("capture stopped")
    }

    // MARK: - Audio thread

    private final class Pipeline: @unchecked Sendable {
        private let converter: AVAudioConverter?
        private let targetFormat: AVAudioFormat
        private let continuation: AsyncStream<AudioChunk>.Continuation
        private let onLevel: @Sendable (Float) -> Void

        init(
            converter: AVAudioConverter?,
            targetFormat: AVAudioFormat,
            continuation: AsyncStream<AudioChunk>.Continuation,
            onLevel: @escaping @Sendable (Float) -> Void
        ) {
            self.converter = converter
            self.targetFormat = targetFormat
            self.continuation = continuation
            self.onLevel = onLevel
        }

        func process(_ buffer: AVAudioPCMBuffer) {
            onLevel(Self.loudness(of: buffer))

            // AVAudioEngine recycles the tap buffer the moment this returns, so the engine
            // must never see it directly. Conversion allocates; the no-conversion path copies.
            guard let converter else {
                if let copy = Self.copy(buffer) {
                    continuation.yield(AudioChunk(buffer: copy))
                }
                return
            }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            // Hand the converter exactly one input buffer, then report "nothing more for now".
            // The input block is invoked synchronously inside `convert`, on this thread.
            nonisolated(unsafe) let source = buffer
            let handedOver = Latch()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if handedOver.fire() {
                    outStatus.pointee = .haveData
                    return source
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            if let error {
                Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard status != .error, output.frameLength > 0 else { return }
            continuation.yield(AudioChunk(buffer: output))
        }

        /// One-shot flag. Returns true exactly once.
        private final class Latch: @unchecked Sendable {
            private var fired = false
            func fire() -> Bool {
                if fired { return false }
                fired = true
                return true
            }
        }

        private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let frames = Int(buffer.frameLength)
            guard frames > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
            else { return nil }
            copy.frameLength = buffer.frameLength

            let channels = Int(buffer.format.channelCount)
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
            } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
                for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
            } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
                for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
            } else {
                return nil
            }
            return copy
        }

        /// RMS of channel 0 mapped from roughly −50…0 dBFS onto 0…1.
        private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-7))
            return min(1, max(0, (db + 50) / 50))
        }
    }
}
