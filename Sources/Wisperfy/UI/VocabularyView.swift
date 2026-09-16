import SwiftUI

/// View state for the Vocabulary window. The variants column is edited as one
/// comma-separated line; the draft keeps what the user typed (including a trailing
/// comma) while the model holds the parsed list.
@MainActor
@Observable
final class VocabularyViewModel {
    var drafts: [VocabularyEntry.ID: String] = [:]
}

/// The user's terms and their known misrecognitions, one row each. Terms are sent to
/// the Apple recognizer as hints and listed in the polish prompt; variants are replaced
/// before the text is typed.
struct VocabularyView: View {
    let vocabulary: Vocabulary
    @Bindable var model: VocabularyViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if vocabulary.entries.isEmpty {
                empty
            } else {
                list
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: VocabularyStyle.minWidth, minHeight: VocabularyStyle.minHeight)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Text("Term")
                .frame(width: VocabularyStyle.termWidth, alignment: .leading)
            Text("Heard as (comma-separated)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Used")
                .frame(width: VocabularyStyle.hitsWidth, alignment: .trailing)
            Color.clear.frame(width: 22)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, VocabularyStyle.padding)
        .frame(height: VocabularyStyle.barHeight)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: VocabularyStyle.rowSpacing) {
                ForEach(vocabulary.entries) { entry in
                    row(entry)
                }
            }
            .padding(VocabularyStyle.padding)
        }
    }

    private func row(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: 12) {
            TextField("Claude Code", text: canonicalBinding(entry))
                .frame(width: VocabularyStyle.termWidth)
            TextField("clot code, cloud code", text: variantsBinding(entry))
                .frame(maxWidth: .infinity)
            Text(entry.hits > 0 ? "\(entry.hits)×" : "–")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: VocabularyStyle.hitsWidth, alignment: .trailing)
            Button {
                model.drafts[entry.id] = nil
                vocabulary.remove(entry.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove term")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13, design: .rounded))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No terms yet")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Add names and products the recognizer gets wrong, or correct a transcript in History and accept the suggestion.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(countLabel)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Add Term") { vocabulary.add(canonical: "") }
                .keyboardShortcut("n", modifiers: .command)
        }
        .controlSize(.small)
        .padding(.horizontal, VocabularyStyle.padding)
        .frame(height: VocabularyStyle.barHeight)
    }

    // MARK: - Bindings

    private func canonicalBinding(_ entry: VocabularyEntry) -> Binding<String> {
        Binding(
            get: { vocabulary.entries.first { $0.id == entry.id }?.canonical ?? "" },
            set: { vocabulary.update(entry.id, canonical: $0) }
        )
    }

    private func variantsBinding(_ entry: VocabularyEntry) -> Binding<String> {
        Binding(
            get: {
                model.drafts[entry.id]
                    ?? vocabulary.entries.first { $0.id == entry.id }?.variants.joined(separator: ", ")
                    ?? ""
            },
            set: { text in
                model.drafts[entry.id] = text
                vocabulary.update(entry.id, variants: text.split(separator: ",").map(String.init))
            }
        )
    }

    private var countLabel: String {
        let count = vocabulary.entries.count
        return count == 1 ? "1 term" : "\(count) terms"
    }
}
