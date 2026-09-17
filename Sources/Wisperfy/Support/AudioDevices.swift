import CoreAudio
import Foundation

/// An audio input device as CoreAudio lists it.
struct InputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// Which microphone to capture from. The built-in one is the default: macOS hands the
/// system default input to AirPods the moment they connect, and dictating at the Mac
/// through earbuds that are on the desk yields silence.
enum MicrophoneChoice: Hashable, Sendable {
    case builtIn
    case systemDefault
    case device(uid: String)

    var rawValue: String {
        switch self {
        case .builtIn: "builtIn"
        case .systemDefault: "system"
        case .device(let uid): "device:" + uid
        }
    }

    init(rawValue: String) {
        if rawValue == "system" {
            self = .systemDefault
        } else if rawValue.hasPrefix("device:") {
            self = .device(uid: String(rawValue.dropFirst("device:".count)))
        } else {
            self = .builtIn
        }
    }
}

/// Read-only CoreAudio HAL queries: cheap property reads, no engine, no IO unit.
enum AudioDevices {
    /// Every device with at least one input channel.
    static func inputDevices() -> [InputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannels(of: id) > 0,
                  let uid = string(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(of: id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let transport = uint32(of: id, selector: kAudioDevicePropertyTransportType) ?? 0
            return InputDevice(id: id, uid: uid, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    static func builtIn() -> InputDevice? {
        inputDevices().first { $0.isBuiltIn }
    }

    static func device(uid: String) -> InputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// The system default input, or nil if there is none.
    static func defaultInput() -> InputDevice? {
        guard let id = uint32(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice),
              id != 0
        else { return nil }
        return inputDevices().first { $0.id == id }
    }

    /// Resolves a choice to a device to select, or nil to leave the system default.
    static func resolve(_ choice: MicrophoneChoice) -> InputDevice? {
        switch choice {
        case .systemDefault:
            return nil
        case .builtIn:
            if let device = builtIn() { return device }
            Log.audio.info("no built-in microphone; using the system default input")
            return nil
        case .device(let uid):
            if let device = device(uid: uid) { return device }
            Log.audio.info("chosen microphone is not connected; using the system default input")
            return nil
        }
    }

    // MARK: - HAL helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}
