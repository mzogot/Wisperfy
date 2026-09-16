import AppKit
import SwiftUI

@main
struct WisperfyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        Log.app.info("Wisperfy launched")
    }
}

/// The menu bar dropdown. Deliberately small: status, actions, history, vocabulary,
/// four settings, quit.
struct MenuContent: View {
    let controller: DictationController
    @Bindable private var settings = Settings.shared

    var body: some View {
        Text(statusLine)

        Divider()

        if controller.mode == .session, controller.state.isActive {
            Button("Done") { controller.finishSession() }
        } else {
            Button("Start Dictation") { controller.startSession() }
                .disabled(controller.state.isActive)
        }
        if !controller.sessionText.isEmpty, !controller.sessionPanelVisible {
            Button("Show Last Transcript") { controller.showSessionPanel() }
        }
        Button("History…") { controller.showHistory() }
        Button("Vocabulary…") { controller.showVocabulary() }

        Divider()

        Picker("Language", selection: $settings.language) {
            ForEach(DictationLanguage.allCases) { language in
                Text(language.label).tag(language)
            }
        }
        Picker("Push to Talk Key", selection: $settings.pushToTalkKey) {
            ForEach(PushToTalkKey.allCases) { key in
                Text(key.label).tag(key)
            }
        }
        Picker("Engine", selection: $settings.engine) {
            ForEach(EnginePreference.allCases) { engine in
                Text(engine.label).tag(engine)
            }
        }
        Toggle("Polish with Apple Intelligence", isOn: $settings.polish)
            .disabled(!PolishFormatter.isAvailable)
        if let reason = PolishFormatter.unavailableReason {
            Text(reason)
        }

        Divider()

        if !controller.hotkeyArmed {
            Button("Grant Accessibility Access…") { Permissions.openAccessibilitySettings() }
        }
        if Permissions.microphoneStatus != .authorized {
            Button("Grant Microphone Access…") { Permissions.openMicrophoneSettings() }
        }

        Divider()

        Button("Quit Wisperfy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard controller.hotkeyArmed else { return "Waiting for Accessibility permission" }
        return "Hold \(settings.pushToTalkKey.label) to dictate, tap it for a session"
    }
}
