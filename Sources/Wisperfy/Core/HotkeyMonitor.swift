import AppKit
import Carbon.HIToolbox
import Foundation

/// The modifier key that holds the microphone open.
enum PushToTalkKey: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case rightCommand
    case fn

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)
        case .rightCommand: Int64(kVK_RightCommand)
        case .fn: Int64(kVK_Function)
        }
    }

    /// The device-specific flag bit for this physical key.
    ///
    /// The public `CGEventFlags.maskAlternate` is set when *either* Option key is down, so
    /// checking it means holding Left ⌥ makes a Right ⌥ release invisible. These raw values
    /// are IOKit's NX_DEVICER*KEYMASK bits, which keep the left/right distinction.
    var deviceFlag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .fn: "fn"
        }
    }

    /// Swallowing fn would break fn+arrows, fn+delete and the emoji picker. Dedicated
    /// right-hand modifiers are safe to consume so the target app never sees them.
    var consumesEvent: Bool { self != .fn }
}

/// Watches a held modifier key through a session-level `CGEventTap`.
///
/// A tap is the only API that distinguishes Right ⌥ from Left ⌥ and can see fn.
/// It requires the Accessibility grant; without it `tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    var key: PushToTalkKey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// - Returns: false when the tap could not be created (almost always missing Accessibility).
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // Pull plain values out before crossing into actor-isolated code; CGEvent
                // is not Sendable. The tap is scheduled on the main run loop, so this
                // callback runs on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let swallow = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("event tap creation failed; Accessibility not granted?")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        Log.hotkey.info("armed on \(self.key.label, privacy: .public)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isPressed = false
        isRunning = false
    }

    /// - Returns: true if the event should be swallowed instead of passed on.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // macOS disables a tap it thinks is too slow; re-enable and carry on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard type == .flagsChanged, keyCode == key.keyCode else { return false }

        let pressedNow = flags.contains(key.deviceFlag)
        guard pressedNow != isPressed else { return false }
        isPressed = pressedNow

        if pressedNow { onPress?() } else { onRelease?() }
        return key.consumesEvent
    }
}
