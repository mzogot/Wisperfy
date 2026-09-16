import AppKit
import SwiftUI

/// Every literal the History window uses.
enum HistoryStyle {
    static let width: CGFloat = 760
    static let height: CGFloat = 480
    static let minWidth: CGFloat = 600
    static let minHeight: CGFloat = 360
    static let listWidth: CGFloat = 280
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 4
    static let barHeight: CGFloat = 44
    static let previewLines = 2
}

/// View state for the History window. Lives outside the view because the Command Line
/// Tools toolchain cannot compile `@State`.
@MainActor
@Observable
final class HistoryViewModel {
    var query = ""
    var selectedID: TranscriptEntry.ID?
    /// Editing the selected transcript in place. `draft` is the text being typed.
    var editing = false
    var draft = ""
    /// Corrections found in the last save, awaiting a yes or no.
    var suggestions: [CorrectionSuggestion] = []
}

/// Two panes: a searchable list of transcripts on the left, the selected transcript with
/// Edit, Copy and Delete on the right. The list and the detail read straight from
/// `TranscriptHistory`, so a dictation finishing while the window is open shows up at once.
///
/// Editing is how the vocabulary learns: saving a changed transcript offers each word
/// substitution as a new mapping.
struct HistoryView: View {
    let history: TranscriptHistory
    let vocabulary: Vocabulary
    @Bindable var model: HistoryViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: HistoryStyle.listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: HistoryStyle.minWidth, minHeight: HistoryStyle.minHeight)
        .onChange(of: model.selectedID) {
            model.editing = false
            model.suggestions = []
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)

            if filtered.isEmpty {
                emptyList
            } else {
                List(filtered, selection: $model.selectedID) { entry in
                    HistoryRow(entry: entry)
                        .tag(entry.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.5)
            sidebarFooter
        }
        .background(.background.secondary)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: $model.query)
                .textFieldStyle(.plain)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, HistoryStyle.padding)
        .frame(height: HistoryStyle.barHeight)
    }

    private var emptyList: some View {
        VStack(spacing: 6) {
            Text(history.entries.isEmpty ? "No transcripts yet" : "No matches")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if history.entries.isEmpty {
                Text("Hold \(Settings.shared.pushToTalkKey.label) and speak.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarFooter: some View {
        HStack {
            Text(countLabel)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Clear All…") { confirmClearAll() }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
        }
        .padding(.horizontal, HistoryStyle.padding)
        .frame(height: HistoryStyle.barHeight)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(spacing: 0) {
                detailHeader(entry)
                Divider().opacity(0.5)
                if model.editing {
                    TextEditor(text: $model.draft)
                        .font(.system(size: 14, design: .rounded))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(HistoryStyle.padding)
                } else {
                    ScrollView {
                        Text(entry.text)
                            .font(.system(size: 14, design: .rounded))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(HistoryStyle.padding)
                    }
                }
                CorrectionReviewView(
                    suggestions: model.suggestions,
                    accept: { suggestion in
                        vocabulary.accept(suggestion)
                        model.suggestions.removeAll { $0.id == suggestion.id }
                    },
                    dismiss: { suggestion in
                        model.suggestions.removeAll { $0.id == suggestion.id }
                    }
                )
                Divider().opacity(0.5)
                detailFooter(entry)
            }
        } else {
            Text("Select a transcript")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private func detailHeader(_ entry: TranscriptEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13, weight: .medium, design: .rounded))
            Text("·").foregroundStyle(.tertiary)
            Text(entry.source.label)
            Text("·").foregroundStyle(.tertiary)
            Text(languageLabel(entry.language))
            if entry.seconds > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(Self.duration(entry.seconds))
            }
            Spacer()
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, HistoryStyle.padding)
        .frame(height: HistoryStyle.barHeight)
    }

    private func detailFooter(_ entry: TranscriptEntry) -> some View {
        HStack(spacing: 10) {
            Text("\(entry.text.count) characters")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            if model.editing {
                Button("Cancel") { model.editing = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { save(entry) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Delete", role: .destructive) { delete(entry) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Edit") { beginEditing(entry) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Copy") { copy(entry) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, HistoryStyle.padding)
        .frame(height: HistoryStyle.barHeight)
    }

    // MARK: - Data

    private var filtered: [TranscriptEntry] {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var selected: TranscriptEntry? {
        history.entries.first { $0.id == model.selectedID }
    }

    private var countLabel: String {
        let total = history.entries.count
        if model.query.isEmpty { return total == 1 ? "1 transcript" : "\(total) transcripts" }
        return "\(filtered.count) of \(total)"
    }

    private func languageLabel(_ raw: String) -> String {
        DictationLanguage(rawValue: raw)?.label ?? raw
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    // MARK: - Actions

    private func copy(_ entry: TranscriptEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        Log.app.info("history: copied \(entry.text.count, privacy: .public) chars to clipboard")
    }

    private func beginEditing(_ entry: TranscriptEntry) {
        model.draft = entry.text
        model.suggestions = []
        model.editing = true
    }

    /// Stores the edit and turns its word-level differences into vocabulary suggestions.
    private func save(_ entry: TranscriptEntry) {
        let corrected = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.editing = false
        guard corrected != entry.text else { return }
        history.update(entry.id, text: corrected)
        model.suggestions = vocabulary.suggestions(original: entry.text, corrected: corrected)
    }

    private func delete(_ entry: TranscriptEntry) {
        // Keep the selection on a neighbour so the detail pane does not go blank.
        let list = filtered
        let index = list.firstIndex(of: entry)
        history.remove(entry.id)
        let remaining = filtered
        if let index, !remaining.isEmpty {
            model.selectedID = remaining[min(index, remaining.count - 1)].id
        } else {
            model.selectedID = nil
        }
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all transcripts?"
        alert.informativeText = "This removes every entry from the history. It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.removeAll()
        model.selectedID = nil
    }
}

/// One list row: when, how, and the first couple of lines of text.
private struct HistoryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryStyle.rowSpacing) {
            HStack {
                Text(entry.date.formatted(.relative(presentation: .named)))
                Spacer()
                Text(entry.source == .session ? "Session" : "PTT")
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)

            Text(entry.text)
                .font(.system(size: 13, design: .rounded))
                .lineLimit(HistoryStyle.previewLines)
        }
        .padding(.vertical, HistoryStyle.rowSpacing)
    }
}
