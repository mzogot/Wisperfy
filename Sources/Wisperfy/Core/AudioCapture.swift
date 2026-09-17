import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// A PCM buffer the capture layer owns outright. Safe to send across isolation only
/// because `AudioCapture` always allocates fresh storage before handing one out.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case startTimedOut
    case unitFailed(step: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .converterUnavailable: "The microphone format cannot be converted for the speech engine."
        case .startTimedOut: "Microphone did not start. Check Sound ▸ Input in System Settings."
        case .unitFailed(let step, let status): "Microphone setup failed: \(step) (\(status))."
        }
    }
}

/// Microphone capture with on-the-fly conversion to the speech engine's format.
///
/// This talks to a HAL output unit (AUHAL) directly, not to `AVAudioEngine`. The
/// engine's input node binds itself to a process-wide aggregate of the system default
/// devices the moment it is touched and caches that format; pinning another device
/// afterwards reads back fine, `start()` returns without error, and then the unit
/// falls back to the aggregate and delivers nothing. With the raw unit the device is
/// set before any format is read, input is enabled on element 1, output is disabled
/// on element 0, and no default-device aggregate is ever created.
///
/// An actor, not main-actor code: `AudioOutputUnitStart` blocks on CoreAudio, and
/// during an input-device switch (AirPods connecting or dropping) that block has
/// lasted forever. On the main thread it froze the whole app. Here it only blocks
/// this actor, and the controller gives up on it after a timeout.
///
/// A fresh unit is created for every capture. A reused one keeps whatever device it
/// last saw, and that is what spun on a vanished device.
///
/// The input callback runs on a real-time audio thread. Everything it touches lives
/// in `Pipeline`, which is only ever used from that thread while capture is running.
actor AudioCapture {
    /// Upper bound on frames per input callback; Bluetooth devices use big slices.
    private static let maximumFramesPerSlice: UInt32 = 8192

    private var unit: AudioUnit?
    private var pipeline: Pipeline?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var isRunning = false

    /// Starts capture and returns an *ordered* stream of converted buffers.
    ///
    /// - Parameters:
    ///   - microphone: which device to capture from; resolved here, off the main thread.
    ///   - onLevel: Called on the audio thread with a 0…1 loudness value.
    func start(
        format: AVAudioFormat,
        microphone: MicrophoneChoice,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw AudioCaptureError.noInputDevice }

        guard let device = AudioDevices.resolve(microphone) ?? AudioDevices.defaultInput() else {
            throw AudioCaptureError.noInputDevice
        }

        let unit = try Self.makeInputUnit()
        self.unit = unit
        do {
            // Device first: every format below is read from it.
            var deviceID = device.id
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                "select \(device.name)"
            )

            // What the hardware delivers on the input element.
            var hardware = AudioStreamBasicDescription()
            var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &descriptionSize),
                "read device format"
            )
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let native = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                      channels: hardware.mChannelsPerFrame, interleaved: false
                  )
            else { throw AudioCaptureError.noInputDevice }

            // What we render: same rate and channels, Float32 non-interleaved, which is
            // the layout `AVAudioPCMBuffer` and `AVAudioConverter` work with.
            var client = native.streamDescription.pointee
            try Self.check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, descriptionSize),
                "set client format"
            )
            var maxFrames = Self.maximumFramesPerSlice
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                    &maxFrames, UInt32(MemoryLayout<UInt32>.size)
                ),
                "set frames per slice"
            )

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

            guard let pipeline = Pipeline(
                unit: unit,
                nativeFormat: native,
                frameCapacity: maxFrames,
                converter: converter,
                targetFormat: format,
                continuation: continuation,
                onLevel: onLevel
            ) else { throw AudioCaptureError.noInputDevice }
            self.pipeline = pipeline

            var callback = AURenderCallbackStruct(
                inputProc: Pipeline.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(pipeline).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "install input callback"
            )

            try Self.check(AudioUnitInitialize(unit), "initialize")
            try Self.check(AudioOutputUnitStart(unit), "start")
            isRunning = true

            // Trust nothing: the log names the device the unit is actually running on.
            var active: AudioDeviceID = 0
            var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &active, &idSize) == noErr,
               active != device.id {
                Log.audio.error("capture is running on device \(active, privacy: .public), not the chosen \(device.name, privacy: .public)")
            }
            Log.audio.info("capture started from \(device.name, privacy: .public): \(native.sampleRate, privacy: .public) Hz → \(format.sampleRate, privacy: .public) Hz")
            return stream
        } catch {
            tearDown()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        tearDown()
        Log.audio.info("capture stopped")
    }

    private func tearDown() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        pipeline = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    // MARK: - HAL output unit

    /// A HAL output unit with input enabled and output disabled: a microphone, nothing else.
    private static func makeInputUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.unitFailed(step: "find HAL unit", status: kAudioUnitErr_InvalidElement)
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "create HAL unit")
        guard let unit = instance else {
            throw AudioCaptureError.unitFailed(step: "create HAL unit", status: kAudioUnitErr_InvalidElement)
        }
        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, flagSize),
                "enable input"
            )
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, flagSize),
                "disable output"
            )
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioCaptureError.unitFailed(step: step, status: status) }
    }

    // MARK: - Audio thread

    private final class Pipeline: @unchecked Sendable {
        private let unit: AudioUnit
        /// Rendered into on every callback and reused; nothing downstream may keep it.
        private let scratch: AVAudioPCMBuffer
        private let converter: AVAudioConverter?
        private let targetFormat: AVAudioFormat
        private let continuation: AsyncStream<AudioChunk>.Continuation
        private let onLevel: @Sendable (Float) -> Void

        init?(
            unit: AudioUnit,
            nativeFormat: AVAudioFormat,
            frameCapacity: UInt32,
            converter: AVAudioConverter?,
            targetFormat: AVAudioFormat,
            continuation: AsyncStream<AudioChunk>.Continuation,
            onLevel: @escaping @Sendable (Float) -> Void
        ) {
            guard let scratch = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: frameCapacity) else { return nil }
            self.unit = unit
            self.scratch = scratch
            self.converter = converter
            self.targetFormat = targetFormat
            self.continuation = continuation
            self.onLevel = onLevel
        }

        /// The C entry point the HAL unit calls on its IO thread. It captures nothing;
        /// the pipeline arrives through `refCon`.
        static let inputCallback: AURenderCallback = { refCon, actionFlags, timestamp, bus, frameCount, _ in
            Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue()
                .render(actionFlags, timestamp, bus: bus, frames: frameCount)
        }

        private func render(
            _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            _ timestamp: UnsafePointer<AudioTimeStamp>,
            bus: UInt32,
            frames: UInt32
        ) -> OSStatus {
            guard frames <= scratch.frameCapacity else { return noErr }   // oversized slice: dropped
            scratch.frameLength = frames
            let status = AudioUnitRender(unit, actionFlags, timestamp, bus, frames, scratch.mutableAudioBufferList)
            guard status == noErr else { return status }
            process(scratch)
            return noErr
        }

        private func process(_ buffer: AVAudioPCMBuffer) {
            onLevel(Self.loudness(of: buffer))

            // The scratch buffer is overwritten by the next callback, so the engine must
            // never see it directly. Conversion allocates; the no-conversion path copies.
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
