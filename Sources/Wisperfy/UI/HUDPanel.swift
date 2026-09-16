import AppKit
import SwiftUI

/// The floating capsule that appears while dictating.
///
/// This panel must never become key or main. If it took focus, the user's text field
/// would lose it and there would be nothing to type into. Everything else here is
/// cosmetic; that one property is what makes the app work.
@MainActor
final class HUDPanel: NSPanel {
    private let hosting: NSHostingView<HUDView>

    init(controller: DictationController) {
        hosting = NSHostingView(rootView: HUDView(controller: controller))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: HUDStyle.width, height: HUDStyle.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        hosting.wantsLayer = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDStyle.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        Log.hud.debug("shown at \(NSStringFromRect(self.frame), privacy: .public)")
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HUDStyle.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        })
    }

    /// Bottom-centre of the screen the user is working on.
    private func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - HUDStyle.width / 2,
            y: visible.minY + HUDStyle.bottomInset
        )
        setFrameOrigin(origin)
    }
}
