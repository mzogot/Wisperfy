import AppKit
import SwiftUI

/// A regular titled window listing every past transcript.
///
/// Wisperfy is a menu bar app with no Dock icon, so the window must ask for activation
/// when shown; otherwise it appears behind the current app and never gets keyboard focus.
/// Unlike the HUD and the session panel it may take focus freely: nothing is being typed
/// into another app while the user is browsing history.
@MainActor
final class HistoryWindow: NSWindow {
    private let model = HistoryViewModel()
    private let history: TranscriptHistory

    init(history: TranscriptHistory, vocabulary: Vocabulary) {
        self.history = history
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: HistoryStyle.width, height: HistoryStyle.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Wisperfy History"
        isReleasedWhenClosed = false
        minSize = NSSize(width: HistoryStyle.minWidth, height: HistoryStyle.minHeight)
        setFrameAutosaveName("HistoryWindow")
        titlebarAppearsTransparent = true
        toolbarStyle = .unified

        let hosting = NSHostingView(rootView: HistoryView(history: history, vocabulary: vocabulary, model: model))
        hosting.wantsLayer = true
        contentView = hosting
    }

    /// Escape closes the window, like any transient window.
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func show() {
        if !isVisible {
            // No saved frame yet on first launch: centre on the screen the user is on.
            if frameAutosaveName.isEmpty || !setFrameUsingName(frameAutosaveName) { center() }
        }
        if model.selectedID == nil || !history.entries.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = history.entries.first?.id
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
