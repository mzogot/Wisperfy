import AVFoundation
import AppKit
import Foundation
import Observation

/// The state machine that ties hotkey, microphone, speech engine, formatter, panels and
/// output together.
///
/// Two modes share one pipeline:
/// - **Push to talk.** Hold the key, speak, release. Text is typed into the focused app.
/// - **Session.** Tap the key (or use the menu). The session panel opens and listens
///   until Done; the result stays visible in the panel.
///
/// In both modes the final text is copied to the clipboard and recorded in
/// `TranscriptHistory`, so nothing is lost if the target app drops the insert.
///
/// Flow in both: `starting` (engine + mic spin up) → `listening` → `finishing`
/// (drain audio, finalize, format, deliver) → `idle`.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    enum Mode: Equatable {
        case pushToTalk
        case session
    }

    private(set) var state: State = .idle
    private(set) var mode: Mode = .pushToTalk
    /// Live transcript, revised as the engine refines it. Drives the HUD.
    private(set) var transcript = ""
    /// Transcript shown in the session panel: live during a session, then the final result.
    private(set) var sessionText = ""
    private(set) var copiedToClipboard = false
    /// Extra status for slow start-ups, e.g. a one-time model download.
    private(set) var hint: String?
    /// Smoothed 0…1 microphone level for the HUD meter.
    private(set) var level: Float = 0
    private(set) var hotkeyArmed = false
    private(set) var sessionPanelVisible = false
    /// Corrections extracted from the user's edits in the session panel, awaiting a
    /// yes or no before they join the vocabulary.
    private(set) var sessionSuggestions: [CorrectionSuggestion] = []

    /// Every finished transcript, newest first. Shown in the History window.
    let history = TranscriptHistory()
    /// The user's terms and their known misrecognitions. Feeds the recognizer, the
    /// mapping pass and the polish prompt.
    let vocabulary = Vocabulary()

    /// A press shorter than this is a tap, which toggles a session instead of dictating.
    private static let tapThreshold: Duration = .milliseconds(350)

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    @ObservationIgnored private lazy var formatter = FormattingPipeline(vocabulary: vocabulary)
    @ObservationIgnored private lazy var hud = HUDPanel(controller: self)
    @ObservationIgnored private lazy var session = SessionPanel(controller: self)
    @ObservationIgnored private lazy var historyWindow = HistoryWindow(history: history, vocabulary: vocabulary)
    @ObservationIgnored private lazy var vocabularyWindow = VocabularyWindow(vocabulary: vocabulary)

    private var engine: (any TranscriptionEngine)?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var releasePending = false
    private var pressedAt: ContinuousClock.Instant?
    private var listeningSince: ContinuousClock.Instant?
    private var permissionPoll: Task<Void, Never>?
    /// The history entry of the last finished session and its text as delivered, so
    /// edits in the panel can be saved and compared.
    private var sessionEntryID: TranscriptEntry.ID?
    private var sessionFinalText = ""

    // MARK: - Lifecycle

    /// Call once at launch. Arms the hotkey as soon as Accessibility is granted.
    func start() {
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        observeSettings()
        armHotkeyWhenTrusted()
    }

    private func armHotkeyWhenTrusted() {
        permissionPoll?.cancel()
        if Permissions.isAccessibilityTrusted {
            rearmHotkey()
            return
        }

        Permissions.promptForAccessibility()
        Log.app.info("waiting for Accessibility grant")
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if Permissions.isAccessibilityTrusted {
                    self.rearmHotkey()
                    return
                }
            }
        }
    }

    private func rearmHotkey() {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkeyArmed = hotkey.start()
    }

    /// Re-arm the tap whenever the user picks a different key in the menu.
    private func observeSettings() {
        withObservationTracking {
            _ = Settings.shared.pushToTalkKey
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if Permissions.isAccessibilityTrusted { self.rearmHotkey() }
                self.observeSettings()
            }
        }
    }

    // MARK: - Key handling

    private func keyPressed() {
        pressedAt = .now
        guard !state.isActive else { return }      // a press during a session is handled on release
        beginUtterance(mode: .pushToTalk)
    }

    private func keyReleased() {
        let quick = pressedAt.map { ContinuousClock.now - $0 < Self.tapThreshold } ?? false
        pressedAt = nil

        if mode == .session {
            if state.isActive { finishSession() }   // any press during a session means Done
            return
        }
        if quick {
            convertToSession()
        } else {
            endUtterance()
        }
    }

    // MARK: - Public actions (menu and panels)

    /// Starts a hands-free session, or does nothing if something is already running.
    func startSession() {
        guard !state.isActive else { return }
        beginUtterance(mode: .session)
    }

    /// Stops listening; the result lands on the clipboard and stays in the panel.
    func finishSession() {
        guard mode == .session else { return }
        switch state {
        case .starting: releasePending = true
        case .listening:
            state = .finishing
            Task { await finishPipeline() }
        default: break
        }
    }

    /// Hides the session panel. A running session is cancelled without output.
    func closeSession() {
        if mode == .session, state.isActive { cancelPipeline() }
        commitSessionEdits(review: false)
        session.hide()
        sessionPanelVisible = false
    }

    func showSessionPanel() {
        session.show()
        sessionPanelVisible = true
    }

    /// Copy is also the moment edits count: the history entry is updated and any
    /// word-level corrections are offered for the vocabulary.
    func copySessionText() {
        commitSessionEdits(review: true)
        copy(sessionText)
    }

    /// The session transcript is editable once the session has finished.
    func editSessionText(_ text: String) {
        guard !state.isActive, mode == .session else { return }
        sessionText = text
    }

    func acceptSuggestion(_ suggestion: CorrectionSuggestion) {
        vocabulary.accept(suggestion)
        sessionSuggestions.removeAll { $0.id == suggestion.id }
    }

    func dismissSuggestion(_ suggestion: CorrectionSuggestion) {
        sessionSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// Opens (or brings forward) the window listing every past transcript.
    func showHistory() {
        historyWindow.show()
    }

    /// Opens (or brings forward) the vocabulary editor.
    func showVocabulary() {
        vocabularyWindow.show()
    }

    /// Saves an edited session transcript to history. With `review`, the differences
    /// become vocabulary suggestions shown in the panel.
    private func commitSessionEdits(review: Bool) {
        guard !state.isActive, let id = sessionEntryID, sessionText != sessionFinalText else { return }
        let original = sessionFinalText
        history.update(id, text: sessionText)
        sessionFinalText = sessionText
        if review {
            sessionSuggestions = vocabulary.suggestions(original: original, corrected: sessionText)
        }
    }

    // MARK: - Utterance

    private func beginUtterance(mode: Mode) {
        guard !state.isActive else { return }
        self.mode = mode
        state = .starting
        transcript = ""
        level = 0
        hint = nil
        releasePending = false
        copiedToClipboard = false
        commitSessionEdits(review: false)
        sessionSuggestions = []
        sessionEntryID = nil
        vocabulary.reloadIfChanged()   // hand-edited vocabulary.json counts from the next utterance
        formatter.prepare()

        switch mode {
        case .pushToTalk:
            hud.show()
        case .session:
            sessionText = ""
            showSessionPanel()
        }

        Task { await startPipeline() }
    }

    /// A tap of the key while push-to-talk is starting or listening becomes a session.
    private func convertToSession() {
        guard mode == .pushToTalk, state.isActive else { return }
        mode = .session
        releasePending = false
        sessionText = transcript
        hud.hide()
        showSessionPanel()
        Log.app.info("converted tap to session")
    }

    private func startPipeline() async {
        guard await Permissions.ensureMicrophone() else {
            fail("Microphone access is off. Enable it in System Settings.")
            return
        }

        let engine = await makeEngine()
        self.engine = engine

        do {
            let format = await engine.preferredFormat()
                ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

            let updates = try await engine.start()
            hint = nil
            updatesTask = Task { [weak self] in
                do {
                    for try await update in updates {
                        await MainActor.run { self?.absorb(update.text) }
                    }
                } catch {
                    Log.speech.error("transcript stream ended with error: \(error.localizedDescription, privacy: .public)")
                }
            }

            let audio = try capture.start(format: format) { [weak self] raw in
                Task { @MainActor in self?.absorbLevel(raw) }
            }

            // One task, one stream, sequential awaits: this is what keeps audio in order.
            feedTask = Task {
                for await chunk in audio {
                    await engine.feed(chunk)
                }
            }

            state = .listening
            listeningSince = .now
            Log.app.info("listening (\(self.mode == .session ? "session" : "push-to-talk", privacy: .public))")

            // The key was released (or Done pressed) before start-up finished.
            if releasePending {
                mode == .session ? finishSession() : endUtterance()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Picks the engine for the current language and engine preference.
    private func makeEngine() async -> any TranscriptionEngine {
        let language = Settings.shared.language
        let preference = Settings.shared.engine

        let useApple: Bool
        switch preference {
        case .apple: useApple = true
        case .parakeet: useApple = false
        case .auto:
            if let locale = language.localeIdentifier {
                useApple = await AppleSpeechEngine.supports(locale)
            } else {
                useApple = false   // auto-detect needs Parakeet
            }
        }

        if useApple {
            let locale = Locale(identifier: language.localeIdentifier ?? "en-GB")
            return AppleSpeechEngine(locale: locale, contextualStrings: vocabulary.hintTerms)
        }
        if !ParakeetModelStore.isDownloaded {
            hint = "Downloading language model, one time (~500 MB)…"
        }
        return ParakeetEngine(language: language)
    }

    private func endUtterance() {
        switch state {
        case .starting:
            releasePending = true
            return
        case .listening:
            break
        default:
            return
        }

        state = .finishing
        Log.app.info("finishing")
        Task { await finishPipeline() }
    }

    private func finishPipeline() async {
        capture.stop()
        await feedTask?.value
        feedTask = nil

        await engine?.finish()

        // The results stream should end once the engine finishes. If it does not, stop
        // waiting and use the latest transcript we have.
        if let updatesTask {
            let drained = await awaitWithTimeout(2) { await updatesTask.value }
            if !drained {
                Log.app.error("results stream did not end; using last transcript")
                updatesTask.cancel()
            }
        }
        updatesTask = nil
        engine = nil

        let formatted = await formatter.run(transcript)
        let text = formatted.text
        transcript = text
        if !formatted.corrections.isEmpty {
            Log.app.info("vocabulary: \(formatted.corrections.count, privacy: .public) correction(s) applied")
        }

        let seconds = listeningSince.map { $0.duration(to: .now).inSeconds } ?? 0
        listeningSince = nil

        // Clipboard first, in both modes: the paste below can be swallowed by the target
        // app, and the user then still has the text one ⌘V away and in the History window.
        var entry: TranscriptEntry?
        if !text.isEmpty {
            copy(text)
            entry = history.add(
                text: text,
                source: mode == .session ? .session : .pushToTalk,
                language: Settings.shared.language,
                seconds: seconds,
                corrections: formatted.corrections
            )
        }

        switch mode {
        case .pushToTalk:
            if text.isEmpty {
                Log.app.info("empty transcript, nothing to insert")
            } else {
                TextInjector.insert(text)
            }
            // Leave the final text visible for a beat so the user sees what was typed.
            try? await Task.sleep(for: .milliseconds(text.isEmpty ? 150 : 450))
            hud.hide()

        case .session:
            sessionText = text
            sessionFinalText = text
            sessionEntryID = entry?.id
            Log.app.info("session finished (\(text.count, privacy: .public) chars)")
        }

        state = .idle
        level = 0
    }

    /// Tears the pipeline down without producing output.
    private func cancelPipeline() {
        capture.stop()
        feedTask?.cancel()
        updatesTask?.cancel()
        feedTask = nil
        updatesTask = nil
        if let engine {
            Task { await awaitWithTimeout(2) { await engine.cancel() } }
        }
        engine = nil
        releasePending = false
        listeningSince = nil
        state = .idle
        level = 0
        Log.app.info("cancelled")
    }

    private func fail(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
        capture.stop()
        feedTask?.cancel()
        updatesTask?.cancel()
        feedTask = nil
        updatesTask = nil
        engine = nil
        hint = nil
        listeningSince = nil
        state = .error(message)

        // The session panel shows the message until closed; the HUD hides itself.
        if mode == .pushToTalk {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                hud.hide()
            }
        }
    }

    // MARK: - Absorbing engine output

    private func absorb(_ text: String) {
        transcript = text
        if mode == .session { sessionText = text }
    }

    private func absorbLevel(_ raw: Float) {
        // Fast attack, slow release, so the meter reads as speech rather than noise.
        level = max(raw, level * 0.82)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedToClipboard = true
        Log.app.info("copied \(text.count, privacy: .public) chars to clipboard")
    }
}
