import AppKit
import Carbon.HIToolbox
import Foundation
import os

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
///
/// The tap callback runs on the main thread but outside any actor context, and it has
/// crashed three times inside the runtime's "am I on the main actor" check (see
/// docs/LESSONS.md, "Isolation check crashes in framework callbacks"). So the callback
/// never asks: it decides press/release from lock-protected state without touching the
/// main actor, and hands the result over with a Task.
@MainActor
final class HotkeyMonitor {
    var key: PushToTalkKey = .rightOption {
        didSet {
            let key = key
            tapState.withLock { $0.key = key; $0.isPressed = false }
        }
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private(set) var isRunning = false
    /// Read from the tap callback to re-enable a tap macOS switched off. Written only
    /// on the main actor, before the tap is enabled and after it is disabled.
    nonisolated(unsafe) private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct TapState {
        var key: PushToTalkKey
        var isPressed = false
    }
    private let tapState = OSAllocatedUnfairLock(initialState: TapState(key: .rightOption))

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
            callback: hotkeyTapCallback,
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
        tapState.withLock { $0.isPressed = false }
        isRunning = false
    }

    /// The tap callback proper. No actor isolation, no isolation check.
    /// - Returns: true if the event should be swallowed instead of passed on.
    nonisolated fileprivate func tapped(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // macOS disables a tap it thinks is too slow; re-enable and carry on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .flagsChanged else { return false }

        // (pressed, swallow) for a real transition of our key, nil otherwise.
        let transition: (pressed: Bool, swallow: Bool)? = tapState.withLock { state in
            guard keyCode == state.key.keyCode else { return nil }
            let pressedNow = flags.contains(state.key.deviceFlag)
            guard pressedNow != state.isPressed else { return nil }
            state.isPressed = pressedNow
            return (pressedNow, state.key.consumesEvent)
        }
        guard let transition else { return false }

        Task { @MainActor in
            if transition.pressed { self.onPress?() } else { self.onRelease?() }
        }
        return transition.swallow
    }
}

/// The C callback handed to `CGEvent.tapCreate`. A file-scope function, not a closure
/// inside the `@MainActor` class: a closure formed there is inferred main-actor isolated
/// and the compiler emits a runtime isolation check at its entry, which crashed when the
/// tap fired from the run loop with no task context (docs/LESSONS.md).
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let swallow = monitor.tapped(type: type, keyCode: keyCode, flags: flags)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
