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
/// Both rely on the HUD being a non-activating panel, so focus never leaves the user's app.
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

    private enum AXResult {
        case inserted
        case notVerified(String)
    }

    // MARK: - Strategy 1: Accessibility

    private static func insertViaAccessibility(_ text: String) -> AXResult {
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else { return .notVerified("no focused element") }
        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
}
