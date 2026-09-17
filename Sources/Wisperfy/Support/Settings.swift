import Foundation
import Observation

/// Which language to transcribe. Auto-detect runs on Parakeet, which identifies the
/// language itself; the fixed choices run on Apple's engine where it supports them.
enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case english
    case german
    case russian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto-detect"
        case .english: "English"
        case .german: "Deutsch"
        case .russian: "Русский"
        }
    }

    /// BCP 47 locale for engines that need one. Nil means "let the engine decide".
    var localeIdentifier: String? {
        switch self {
        case .auto: nil
        case .english: "en-GB"
        case .german: "de-DE"
        case .russian: "ru-RU"
        }
    }
}

/// Which speech engine to use. Auto picks Apple for languages it supports (streaming
/// live text, no download) and Parakeet otherwise.
enum EnginePreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case apple
    case parakeet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Automatic"
        case .apple: "Apple (on-device)"
        case .parakeet: "Parakeet (on-device)"
        }
    }
}

/// User preferences, persisted to UserDefaults. Observable so the menu, the panels and
/// the controller all react to changes without a restart.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let pushToTalkKey = "pushToTalkKey"
        static let language = "language"
        static let engine = "engine"
        static let polish = "polish"
        static let concealClipboard = "concealClipboard"
        static let microphone = "microphone"
    }

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Key.pushToTalkKey) }
    }

    var language: DictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    var engine: EnginePreference {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    /// Run the transcript through Apple's on-device language model after the rules and
    /// the vocabulary. Only takes effect where Apple Intelligence is available.
    var polish: Bool {
        didSet { defaults.set(polish, forKey: Key.polish) }
    }

    /// Mark clipboard writes as concealed so cooperating clipboard managers skip them.
    /// Off by default: with a manager that honours it, the "one ⌘V away" safety net is
    /// gone as soon as the user copies something else.
    var concealClipboard: Bool {
        didSet { defaults.set(concealClipboard, forKey: Key.concealClipboard) }
    }

    /// Which microphone to capture from. Built-in by default, see `MicrophoneChoice`.
    var microphone: MicrophoneChoice {
        didSet { defaults.set(microphone.rawValue, forKey: Key.microphone) }
    }

    private init() {
        pushToTalkKey = PushToTalkKey(rawValue: defaults.string(forKey: Key.pushToTalkKey) ?? "")
            ?? .rightOption
        language = DictationLanguage(rawValue: defaults.string(forKey: Key.language) ?? "")
            ?? .auto
        engine = EnginePreference(rawValue: defaults.string(forKey: Key.engine) ?? "")
            ?? .auto
        polish = defaults.object(forKey: Key.polish) as? Bool ?? true
        concealClipboard = defaults.bool(forKey: Key.concealClipboard)
        microphone = MicrophoneChoice(rawValue: defaults.string(forKey: Key.microphone) ?? "")
    }
}
