import AppKit

/// The one place that writes the general pasteboard.
///
/// Whatever lands here is archived by clipboard managers and offered to the user's other
/// devices through Universal Clipboard. That is deliberate: the transcript must stay
/// one ⌘V away in case the target app swallowed the paste. Users who dictate sensitive
/// text can opt in to the nspasteboard.org "concealed" marker, which cooperating
/// managers (Maccy, Paste, Alfred, Raycast, 1Password) honour by not recording the
/// item. It is a convention, not an OS boundary, hence opt-in and documented as such.
@MainActor
enum Clipboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func set(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if Settings.shared.concealClipboard {
            pasteboard.setString("", forType: concealedType)
        }
    }
}
