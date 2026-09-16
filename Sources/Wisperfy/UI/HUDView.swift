import SwiftUI

/// Every literal the HUD uses. Views reference these, never raw numbers.
enum HUDStyle {
    static let width: CGFloat = 380
    static let height: CGFloat = 52
    static let bottomInset: CGFloat = 72
    static let horizontalPadding: CGFloat = 18
    static let itemSpacing: CGFloat = 14

    static let dotSize: CGFloat = 8
    static let barCount = 5
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3
    static let barMinHeight: CGFloat = 4
    static let barMaxHeight: CGFloat = 20

    static let fadeIn: TimeInterval = 0.16
    static let fadeOut: TimeInterval = 0.22
    static let meterResponse: TimeInterval = 0.08

    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let hairline = Color.primary.opacity(0.08)
}

/// Minimal capsule: status dot, a small level meter, one line of live transcript.
struct HUDView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: HUDStyle.itemSpacing) {
            StatusDot(state: controller.state)
            LevelMeter(level: controller.level, active: controller.state == .listening)

            Text(caption)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.identity)
        }
        .padding(.horizontal, HUDStyle.horizontalPadding)
        .frame(width: HUDStyle.width, height: HUDStyle.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(HUDStyle.hairline, lineWidth: 0.5))
    }

    private var caption: String {
        if !controller.transcript.isEmpty { return controller.transcript }
        switch controller.state {
        case .idle: return ""
        case .starting: return controller.hint ?? "Getting ready…"
        case .listening: return "Listening…"
        case .finishing: return "Transcribing…"
        case .error(let message): return message
        }
    }
}

struct StatusDot: View {
    let state: DictationController.State

    var body: some View {
        // No @State here on purpose: the Command Line Tools toolchain lacks the SwiftUI
        // macro plugin, so the pulse is driven by a phase animator instead.
        Circle()
            .fill(color)
            .frame(width: HUDStyle.dotSize, height: HUDStyle.dotSize)
            .phaseAnimator([false, true]) { dot, expanded in
                dot
                    .scaleEffect(state == .listening && expanded ? 1.25 : 1)
                    .opacity(state == .listening && expanded ? 0.7 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
    }

    private var color: Color {
        switch state {
        case .listening: HUDStyle.recording
        case .starting, .finishing: .secondary
        case .error: .orange
        case .idle: .clear
        }
    }
}

private struct LevelMeter: View {
    let level: Float
    let active: Bool

    /// Per-bar sensitivity so the meter reads as a waveform rather than a stack.
    private static let weights: [Float] = [0.55, 0.85, 1.0, 0.85, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: HUDStyle.barSpacing) {
            ForEach(0..<HUDStyle.barCount, id: \.self) { index in
                Capsule()
                    .fill(active ? Color.primary : Color.secondary.opacity(0.5))
                    .frame(width: HUDStyle.barWidth, height: height(for: index))
            }
        }
        .frame(height: HUDStyle.barMaxHeight)
        .animation(.easeOut(duration: HUDStyle.meterResponse), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let scaled = active ? CGFloat(level * Self.weights[index]) : 0
        return HUDStyle.barMinHeight + (HUDStyle.barMaxHeight - HUDStyle.barMinHeight) * scaled
    }
}
