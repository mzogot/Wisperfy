import AppKit
import SwiftUI

/// View state for the Vocabulary window. The variants column is edited as one
/// comma-separated line; the draft keeps what the user typed (including a trailing
/// comma) while the model holds the parsed list.
@MainActor
@Observable
final class VocabularyViewModel {
    var query = ""
    var drafts: [VocabularyEntry.ID: String] = [:]
    /// Spell-checker verdicts, so a row is not re-checked on every redraw.
    @ObservationIgnored private var commonWords: [String: Bool] = [:]

    /// Whether the system dictionary for any dictation language knows `word`. A
    /// variant like "cloud" would then rewrite every real mention of the cloud.
    func isCommonWord(_ word: String) -> Bool {
        let key = word.lowercased()
        if let known = commonWords[key] { return known }
        let checker = NSSpellChecker.shared
        let languages = checker.availableLanguages.filter { available in
            DictationLanguage.allCases.contains { language in
                guard let code = language.localeIdentifier?.prefix(2) else { return false }
                return available.hasPrefix(code)
            }
        }
        let common = languages.contains { language in
            checker.checkSpelling(of: key, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        commonWords[key] = common
        return common
    }
}

/// The user's terms and their known misrecognitions, one row each. Terms are sent to
/// the Apple recognizer as hints and listed in the polish prompt; variants are replaced
/// before the text is typed.
struct VocabularyView: View {
    let vocabulary: Vocabulary
    @Bindable var model: VocabularyViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)
            if let error = vocabulary.loadError {
                loadErrorBanner(error)
                Divider().opacity(0.5)
            }
            header
            Divider().opacity(0.5)
            if filtered.isEmpty {
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search terms", text: $model.query)
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
        .padding(.horizontal, VocabularyStyle.padding)
        .frame(height: VocabularyStyle.barHeight)
    }

    private func loadErrorBanner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("vocabulary.json could not be read (\(error)). Fix the file or delete it; nothing is saved until it loads.")
                .font(.system(size: 12, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reload") { vocabulary.reloadIfChanged() }
                .controlSize(.small)
        }
        .padding(.horizontal, VocabularyStyle.padding)
        .padding(.vertical, VocabularyStyle.rowSpacing)
        .background(.orange.opacity(0.12))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Term")
                .frame(width: VocabularyStyle.termWidth, alignment: .leading)
            Text("Heard as (comma-separated)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Used")
                .frame(width: VocabularyStyle.hitsWidth, alignment: .trailing)
            Color.clear.frame(width: VocabularyStyle.iconWidth)
            Color.clear.frame(width: VocabularyStyle.iconWidth)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, VocabularyStyle.padding)
        .frame(height: VocabularyStyle.barHeight)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: VocabularyStyle.rowSpacing) {
                ForEach(filtered) { entry in
                    row(entry)
                }
            }
            .padding(VocabularyStyle.padding)
        }
    }

    private func row(_ entry: VocabularyEntry) -> some View {
        let warnings = vocabulary.warnings(for: entry, isCommonWord: model.isCommonWord)
        return VStack(alignment: .leading, spacing: VocabularyStyle.rowSpacing / 2) {
            HStack(spacing: 12) {
                TextField("Claude Code", text: canonicalBinding(entry))
                    .frame(width: VocabularyStyle.termWidth)
                TextField("clot code, cloud code", text: variantsBinding(entry))
                    .frame(maxWidth: .infinity)
                Text(entry.hits > 0 ? "\(entry.hits)×" : "–")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: VocabularyStyle.hitsWidth, alignment: .trailing)
                Group {
                    if warnings.isEmpty {
                        Color.clear
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(warnings.map(\.message).joined(separator: "\n"))
                    }
                }
                .frame(width: VocabularyStyle.iconWidth)
                Button {
                    model.drafts[entry.id] = nil
                    vocabulary.remove(entry.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: VocabularyStyle.iconWidth)
                .help("Remove term")
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, design: .rounded))

            if let first = warnings.first {
                Text(first.message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(vocabulary.entries.isEmpty ? "No terms yet" : "No matches")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if vocabulary.entries.isEmpty {
                Text("Add names and products the recognizer gets wrong, or correct a transcript in History and accept the suggestion.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(countLabel)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Add Term") {
                model.query = ""
                vocabulary.add(canonical: "")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(vocabulary.loadError != nil)
        }
        .controlSize(.small)
        .padding(.horizontal, VocabularyStyle.padding)
        .frame(height: VocabularyStyle.barHeight)
    }

    // MARK: - Data

    private var filtered: [VocabularyEntry] {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return vocabulary.entries }
        return vocabulary.entries.filter { entry in
            entry.canonical.localizedCaseInsensitiveContains(query)
                || entry.variants.contains { $0.localizedCaseInsensitiveContains(query) }
        }
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
        let total = vocabulary.entries.count
        if model.query.isEmpty { return total == 1 ? "1 term" : "\(total) terms" }
        return "\(filtered.count) of \(total)"
    }
}
