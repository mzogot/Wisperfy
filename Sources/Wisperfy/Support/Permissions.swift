import AVFoundation
import AppKit
import ApplicationServices

/// The two grants the app cannot work without. Neither can be requested silently:
/// Accessibility is a manual toggle in System Settings, Microphone is a one-time prompt.
enum Permissions {
    // MARK: Accessibility (event tap + AX text insert)

    @MainActor
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "Wisperfy would like to control this computer" dialog once.
    @MainActor
    static func promptForAccessibility() {
        // The literal spelling of kAXTrustedCheckOptionPrompt; the global itself is a
        // mutable C var that Swift 6 strict concurrency refuses to touch.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: Microphone

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Returns true once the microphone is usable, prompting if the user has never been asked.
    static func ensureMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @MainActor
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @MainActor
    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
