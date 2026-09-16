import AppKit
import SwiftUI

/// A regular titled window for editing the vocabulary. Like the History window it
/// activates the app when shown, because an `LSUIElement` app otherwise opens it
/// behind everything.
@MainActor
final class VocabularyWindow: NSWindow {
    private let model = VocabularyViewModel()

    init(vocabulary: Vocabulary) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: VocabularyStyle.width, height: VocabularyStyle.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Wisperfy Vocabulary"
        isReleasedWhenClosed = false
        minSize = NSSize(width: VocabularyStyle.minWidth, height: VocabularyStyle.minHeight)
        setFrameAutosaveName("VocabularyWindow")
        titlebarAppearsTransparent = true
        toolbarStyle = .unified

        let hosting = NSHostingView(rootView: VocabularyView(vocabulary: vocabulary, model: model))
        hosting.wantsLayer = true
        contentView = hosting
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        // Drafts only matter while typing; the model already holds the parsed lists.
        model.drafts.removeAll()
        super.close()
    }

    func show() {
        if !isVisible {
            if frameAutosaveName.isEmpty || !setFrameUsingName(frameAutosaveName) { center() }
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
