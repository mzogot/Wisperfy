import SwiftUI

enum SessionStyle {
    static let width: CGFloat = 460
    static let height: CGFloat = 300
    static let cornerRadius: CGFloat = 18
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 48
}

/// Hands-free dictation: a status header, a scrollable selectable transcript, and the
/// Done / Copy / Close actions. Kept deliberately sparse.
///
/// Once a session has finished the transcript can be edited in place; Copy saves the
/// edit to history and offers any word substitutions for the vocabulary.
struct SessionView: View {
    let controller: DictationController
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            transcript
            CorrectionReviewView(
                suggestions: controller.sessionSuggestions,
                accept: { controller.acceptSuggestion($0) },
                dismiss: { controller.dismissSuggestion($0) }
            )
            Divider().opacity(0.5)
            footer
        }
        .frame(width: SessionStyle.width, height: SessionStyle.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SessionStyle.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SessionStyle.cornerRadius, style: .continuous)
                .strokeBorder(HUDStyle.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(state: controller.state)
            Text(status)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Picker("Language", selection: $settings.language) {
                ForEach(DictationLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(controller.state.isActive)

            Button {
                controller.closeSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, SessionStyle.padding)
        .frame(height: SessionStyle.headerHeight)
    }

    @ViewBuilder
    private var transcript: some View {
        if editable {
            TextEditor(text: editedText)
                .font(.system(size: 14, design: .rounded))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(SessionStyle.padding)
        } else {
            ScrollView {
                Text(controller.sessionText.isEmpty ? placeholder : controller.sessionText)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(controller.sessionText.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(SessionStyle.padding)
            }
        }
    }

    private var editable: Bool {
        !controller.state.isActive && !controller.sessionText.isEmpty
    }

    private var editedText: Binding<String> {
        Binding(
            get: { controller.sessionText },
            set: { controller.editSessionText($0) }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footnote)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            if controller.state.isActive {
                Button("Done") { controller.finishSession() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(controller.state == .finishing)
            } else {
                Button("New") { controller.startSession() }
                    .controlSize(.regular)
                Button("Copy") { controller.copySessionText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(controller.sessionText.isEmpty)
            }
        }
        .padding(.horizontal, SessionStyle.padding)
        .frame(height: SessionStyle.footerHeight)
    }

    // MARK: - Copy

    private var status: String {
        switch controller.state {
        case .starting: controller.hint ?? "Getting ready…"
        case .listening: "Listening…"
        case .finishing: "Transcribing…"
        case .error(let message): message
        case .idle: controller.sessionText.isEmpty ? "Ready" : "Done"
        }
    }

    private var placeholder: String {
        controller.state.isActive ? "Speak, then press Done." : "Press New and start speaking."
    }

    private var footnote: String {
        if controller.copiedToClipboard { return "Copied to clipboard" }
        if controller.state.isActive { return "Tap \(settings.pushToTalkKey.label) or press Return to finish" }
        return ""
    }
}
