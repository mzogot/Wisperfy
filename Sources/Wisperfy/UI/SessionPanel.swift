import AppKit
import SwiftUI

/// The hands-free dictation window: live transcript, Done, Copy, Close.
///
/// Unlike the HUD this panel *can* become key, so the user can click its buttons and
/// select text in it. It is still non-activating: clicking it does not bring Wisperfy
/// to the front or hide whatever app the user is working in.
@MainActor
final class SessionPanel: NSPanel {
    private let hosting: NSHostingView<SessionView>

    init(controller: DictationController) {
        hosting = NSHostingView(rootView: SessionView(controller: controller))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SessionStyle.width, height: SessionStyle.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        hosting.wantsLayer = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel, like any transient window.
    override func cancelOperation(_ sender: Any?) {
        (hosting.rootView.controller).closeSession()
    }

    func show() {
        if !isVisible { reposition() }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDStyle.fadeIn
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HUDStyle.fadeOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        })
    }

    /// Bottom-centre of the current screen, same anchor as the HUD.
    private func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visible.midX - SessionStyle.width / 2,
            y: visible.minY + HUDStyle.bottomInset
        ))
    }
}
