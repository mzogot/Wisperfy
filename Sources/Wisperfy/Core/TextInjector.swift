import AppKit
import ApplicationServices
import Foundation

/// Types text into whatever control currently has keyboard focus.
///
/// Strategy 1 writes `kAXSelectedTextAttribute` on the focused element through the
/// Accessibility API. It is instant. The catch: Electron apps, Chrome and most terminals
/// report the attribute as settable, accept the write, return success, and drop it on
/// the floor. So success is only trusted when the caret is observed to have moved.
///
/// Strategy 2 puts the text on the pasteboard and posts ⌘V. The pasteboard is left as is
/// afterwards on purpose: the controller has already copied the transcript there so the
/// user can paste it again if the target app swallowed the first paste.
///
/// Strategy 3 exists for password fields only: the text is typed as keystrokes, so it
/// never touches the pasteboard, and the controller keeps no copy of it.
///
/// All rely on the HUD being a non-activating panel, so focus never leaves the user's app.
@MainActor
enum TextInjector {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count, privacy: .public) chars)")
        case .notVerified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)); pasting")
            insertViaPasteboard(text)
        }
    }

    /// True when keyboard focus is in a password-style field. Native secure fields and
    /// WebKit/Chromium password inputs report the `AXSecureTextField` subrole. Terminal
    /// password prompts do not; there is nothing to detect there.
    static func focusedElementIsSecure() -> Bool {
        guard let element = focusedElement() else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success,
              let subrole = ref as? String
        else { return false }
        return subrole == kAXSecureTextFieldSubrole
    }

    private enum AXResult {
        case inserted
        case notVerified(String)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else { return nil }
        return unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
    }

    // MARK: - Strategy 1: Accessibility

    private static func insertViaAccessibility(_ text: String) -> AXResult {
        guard let element = focusedElement() else { return .notVerified("no focused element") }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return .notVerified("selected text not settable") }

        // Without a readable caret there is no way to tell a real insert from a dropped one.
        guard let before = selectedRange(of: element) else {
            return .notVerified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return .notVerified("set attribute failed")
        }

        guard let after = selectedRange(of: element) else {
            return .notVerified("selection unreadable after write")
        }

        // A movement check, not an exact-length check: apps normalise newlines or run
        // autocorrect, so the caret may advance by a different amount. Only a completely
        // unmoved selection proves nothing happened. Falling back after a real insert
        // would paste the text twice, which is worse than missing it.
        if after.location == before.location && after.length == before.length {
            return .notVerified("caret did not move")
        }
        return .inserted
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref
        else { return nil }
        let value = unsafeDowncast(ref as AnyObject, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Pasteboard + ⌘V

    private static func insertViaPasteboard(_ text: String) {
        Clipboard.set(text)

        Task { @MainActor in
            // Let the target observe the new pasteboard generation before ⌘V lands.
            try? await Task.sleep(for: .milliseconds(40))
            postCommandV()
            Log.inject.info("pasted (\(text.count, privacy: .public) chars)")
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        // Explicit flags: never inherit whatever the user is still resting a finger on.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Strategy 3: keystrokes, for password fields

    /// One keyboard event carries at most this many UTF-16 units.
    private static let keystrokeChunk = 20

    /// Types the text as keystrokes. Nothing is put on the pasteboard, and the AX path is
    /// skipped because a secure field hides its caret, so an insert could not be verified.
    static func typePrivately(_ text: String) {
        guard !text.isEmpty, let source = CGEventSource(stateID: .privateState) else { return }

        var buffer: [UniChar] = []
        func flush() {
            guard !buffer.isEmpty,
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            buffer.withUnsafeBufferPointer { units in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
            }
            // Explicit flags: the user may still be lifting off the push-to-talk modifier.
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            buffer.removeAll(keepingCapacity: true)
        }

        // Chunk on character boundaries so a surrogate pair never splits across events.
        for character in text {
            let units = Array(String(character).utf16)
            if buffer.count + units.count > keystrokeChunk { flush() }
            buffer += units
        }
        flush()
        Log.inject.info("typed privately (\(text.count, privacy: .public) chars)")
    }
}
