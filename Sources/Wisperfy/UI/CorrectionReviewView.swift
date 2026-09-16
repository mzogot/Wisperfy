import SwiftUI

/// Every literal the correction strip and the Vocabulary window use.
enum VocabularyStyle {
    static let width: CGFloat = 640
    static let height: CGFloat = 420
    static let minWidth: CGFloat = 520
    static let minHeight: CGFloat = 300
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let barHeight: CGFloat = 44
    static let termWidth: CGFloat = 180
    static let hitsWidth: CGFloat = 48
    static let stripSpacing: CGFloat = 6
    static let stripMaxHeight: CGFloat = 96
}

/// "Heard X, you meant Y. Add to vocabulary?" for each substitution found in a user's
/// edit. Shown under an edited transcript in the History window and the session panel.
struct CorrectionReviewView: View {
    let suggestions: [CorrectionSuggestion]
    let accept: (CorrectionSuggestion) -> Void
    let dismiss: (CorrectionSuggestion) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: VocabularyStyle.stripSpacing) {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .foregroundStyle(.secondary)
                        Text("“\(suggestion.heard)” → “\(suggestion.meant)”")
                            .font(.system(size: 12, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Skip") { dismiss(suggestion) }
                        Button("Add to Vocabulary") { accept(suggestion) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, VocabularyStyle.padding)
            .padding(.vertical, VocabularyStyle.rowSpacing)
            .frame(maxHeight: VocabularyStyle.stripMaxHeight)
            .background(.quaternary.opacity(0.4))
        }
    }
}
