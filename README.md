# Wisperfy

Push-to-talk dictation for macOS. Hold a key, talk, release, and clean text lands in
whatever has focus. Everything runs on this Mac: no cloud, no account, no cost.

**Status:** early release, see the [changelog](CHANGELOG.md). Two ways to dictate, three languages, two on-device engines.

- **Push to talk.** Hold the key, speak, release. Text is typed into the focused app.
- **Session.** Tap the key (or use the menu). A panel opens and listens until you press
  Done. The result is copied to the clipboard and stays in the panel, selectable, until
  you close it.
- **Languages.** English, German, Russian, or auto-detect.

## Download

Grab `Wisperfy-<version>.dmg` from the
[latest release](https://github.com/mzogot/Wisperfy/releases/latest), open it and drag
Wisperfy to Applications. The app is signed with a Developer ID and notarized by Apple,
so it opens without warnings. It lives in the menu bar; there is no Dock icon.

Requires macOS 26 or later. Apple silicon is recommended: the Parakeet engine runs on
the Neural Engine and the optional polish step needs Apple Intelligence. The first
dictation in Auto-detect or Russian downloads the Parakeet model (~500 MB) once.

## Build from source

```bash
make install     # build, bundle, sign, copy to /Applications, launch
```

Needs a Swift 6 toolchain; the Xcode Command Line Tools are enough, Xcode is not needed.
A Developer ID certificate is auto-detected for signing. Without one the build is
signed ad hoc, which works but macOS forgets the permission grants on every rebuild.
`make dmg` and `make notarize` produce the release image (see the Makefile for the
credentials file it expects). Releases are cut with `make bump` and `make release`;
see [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## First run

Two permissions are required and neither can be granted silently:

| Permission | Where | Used for |
|---|---|---|
| Accessibility | System Settings ▸ Privacy & Security ▸ Accessibility | Seeing the push-to-talk key and inserting text |
| Microphone | Prompted the first time you hold the key | Audio capture |

Add Wisperfy under Accessibility, then hold **Right ⌥** and talk. The app notices the
grant on its own; no relaunch needed. Tap the key instead of holding it to open a session.

If you choose **fn** as the key, set System Settings ▸ Keyboard ▸ "Press fn key to" to
**Do Nothing**, otherwise macOS also opens its own emoji or dictation panel on every tap.

Other targets: `make run` (run from the build cache), `make logs` (live log stream),
`make reset-permissions` (resets only this app's grants), `make clean`.

## Privacy

Nothing leaves your Mac. There is no account, no telemetry and no network access
except the one-time Parakeet model download from Hugging Face. Audio is processed in
memory and never written to disk. Transcripts are kept locally so you can look them up
and correct them:

| File | Contents |
|---|---|
| `~/Library/Application Support/Wisperfy/history.json` | the last 500 transcripts |
| `~/Library/Application Support/Wisperfy/vocabulary.json` | your terms and their misheard variants |

Delete either file to clear it. Uninstall by dragging Wisperfy out of Applications and
removing that folder.

## Languages and engines

| Language setting | Engine | Live text | Notes |
|---|---|---|---|
| Auto-detect (default) | Parakeet v3 | every ~2 s | detects en/de/ru (and 22 more) per utterance |
| English, Deutsch | Apple SpeechAnalyzer | streaming | no download, ships with macOS 26 |
| Русский | Parakeet v3 | every ~2 s | Apple's engine has no Russian model |

Parakeet runs through [FluidAudio](https://github.com/FluidInference/FluidAudio) as CoreML
on the Neural Engine. Its model (~500 MB) is downloaded once on first use into
`~/Library/Application Support/FluidAudio/Models/` and never leaves the machine. The
Engine menu can force either engine; Apple's simply fails for languages it lacks.

## How it works

```
hold key ─► HotkeyMonitor ─► DictationController
                                   │
                    ┌──────────────┼──────────────────┐
                    ▼              ▼                  ▼
              AudioCapture   HUDPanel / SessionPanel   TranscriptionEngine
                    │                                  (Apple | Parakeet)
               ordered chunks ────────────────────────►│◄── vocabulary hints (Apple)
                                                       ▼
                                              FormattingPipeline
                                        rules ─► vocabulary ─► polish (optional)
                                                       │
                              push to talk ◄───────────┴──────────► session
                                    ▼                                  ▼
                              TextInjector ─► focused app        clipboard + panel
                                                                       │ edit, Copy
                                                    Vocabulary ◄── suggestions
```

Decisions that are load-bearing:

- **The HUD never takes focus.** It is a non-activating panel. If it became key, the
  user's text field would lose focus and there would be nothing to type into. The
  session panel *can* become key (buttons, text selection) but is still non-activating,
  so it never brings Wisperfy to the front.
- **Tap vs hold.** A press shorter than 350 ms is a tap and toggles a session; anything
  longer is push to talk. The pipeline is already running by the time the tap is
  recognised, so converting is just a change of mode.
- **The hotkey is a `CGEventTap`.** It is the only API that tells Right ⌥ from Left ⌥
  and can see fn. That is why Accessibility is a hard requirement.
- **Audio is fed in order.** One task drains one stream with sequential awaits.
  A task per buffer would silently scramble the transcript.
- **Buffers are copied.** `AVAudioEngine` recycles the tap buffer as soon as the
  callback returns.
- **AX insert is verified by caret movement.** Electron apps, Chrome and terminals
  accept the write and drop it. If the caret did not move, fall back to paste.
- **Signing is stable.** macOS keys permission grants to the code signature. The
  Makefile signs with your Developer ID so grants survive rebuilds.

Two protocols are the swap points: `TranscriptionEngine` (add Parakeet, Whisper) and
`TextFormatter` (the pipeline's tiers).

## Vocabulary and learning

Names and products get misheard: "Claude Code" arrives as "clot code" or "cloud code".
Three layers fix that, all on-device:

1. **Recognizer hints.** Every term in the vocabulary is passed to Apple's speech engine
   as a contextual string, so it prefers that spelling in the first place. Parakeet has
   no such hook; the next two layers cover it.
2. **Mapping table.** Each term lists the variants it has been heard as. They are
   replaced on word boundaries, case-insensitively, in any script ("Клод код" works).
   Only exact variants are replaced; a lone common word like "cloud" is never mapped.
3. **Polish.** With Apple Intelligence enabled, the transcript is passed through Apple's
   on-device Foundation Models model with the glossary in its instructions, so it can
   fix a misheard term from context and tidy punctuation. It is bounded by a timeout,
   its output is sanity-checked, and it is skipped for languages the model does not
   support (Russian among them). Toggle it in the menu.

The vocabulary learns from you. Edit a transcript in History (or in the session panel,
then press Copy) and each word-level substitution is offered once: *“clot code” →
“Claude Code”, Add to Vocabulary?* Accepted pairs become variants, and the term joins
the recognizer hints for the next dictation. The file lives at
`~/Library/Application Support/Wisperfy/vocabulary.json` and can be edited from the
menu under Vocabulary…

## Layout

```
Sources/Wisperfy/
├── WisperfyApp.swift            @main, menu bar item, app delegate
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         CGEventTap on modifier changes
│   ├── AudioCapture.swift          AVAudioEngine tap, format conversion, level
│   └── TextInjector.swift          AX insert with fallback to paste
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol
│   ├── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber (streaming)
│   └── ParakeetEngine.swift        Parakeet v3 via FluidAudio (batch + periodic partials)
├── Formatting/
│   ├── TextFormatter.swift         protocol + RuleBasedFormatter
│   ├── FormattingPipeline.swift    rules → vocabulary → polish → vocabulary
│   ├── VocabularyFormatter.swift   deterministic variant → term replacement
│   └── PolishFormatter.swift       Apple Foundation Models, glossary in the prompt
├── UI/
│   ├── HUDPanel.swift              non-activating floating panel (push to talk)
│   ├── HUDView.swift               capsule: status dot, level meter, live text
│   ├── SessionPanel.swift          key-capable floating panel (session)
│   ├── SessionView.swift           header, editable transcript, Done / Copy / New
│   ├── HistoryWindow.swift, HistoryView.swift   past transcripts, editable
│   ├── VocabularyWindow.swift, VocabularyView.swift   terms and their variants
│   └── CorrectionReviewView.swift  "heard X, meant Y" strip under an edited transcript
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift, Timeout.swift
    ├── TranscriptHistory.swift     history.json, capped at 500 entries
    └── Vocabulary.swift            vocabulary.json, WordDiff, suggestions
Tests/WisperfyTests/                 swift test: formatters, vocabulary, diffs, polish
```

## Toolchain note

The Command Line Tools ship the Observation macros but not the SwiftUI ones, so
`@State` and friends do not compile here. Views keep their state in `@Observable`
objects or use phase animators. Everything else in SwiftUI works.

## Roadmap

1. Spoken corrections in the polish tier ("scratch that", "new paragraph")
2. Local model for polishing languages Apple Intelligence lacks (Russian)
3. Onboarding window for the two permissions
4. Branding: HUD motion, settings window

## License

MIT, see [LICENSE](LICENSE). Bundled third-party software is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
