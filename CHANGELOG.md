# Changelog

All notable changes to Wisperfy are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/): while the major version is 0, a minor
bump may change behaviour, a patch bump only fixes.

Every release starts by moving the Unreleased section into a new version heading
(`make bump VERSION=x.y.z`), then `make release` builds, notarizes, tags and publishes.

## [Unreleased]

### Fixed

- The chosen microphone is now really used while AirPods (or another headset) are the
  system default. The audio engine used to accept the choice, report success and then
  capture nothing, so dictating with AirPods in and the MacBook mic selected produced
  no text. Capture now drives the HAL output unit directly.
- The app's own private aggregate device (`CADefaultDeviceAggregate-…`) no longer
  appears in the Microphone menu.

## [0.3.0] - 2026-09-17

### Added

- Password fields are private: when the focused control is a secure text field, the
  dictation is typed as keystrokes and nothing is kept (no HUD text, no formatting, no
  clipboard, no history).
- "Hide from Clipboard Managers" menu setting marks transcripts as concealed so
  cooperating clipboard managers do not archive them. Off by default.
- A Security section in the README describing the September 2026 code review and the
  measures in place.
- `make test` fails if transcript text is ever interpolated into a log line.
- "About Wisperfy" in the menu shows the version and build number.
- Microphone setting in the menu: Built-in Microphone (default), System Default, or a
  specific input device. AirPods and other headsets no longer take over dictation
  just by connecting; pick them explicitly if you want them.
- The log records the peak input level of every utterance, so a silent microphone is
  visible at a glance.

### Changed

- Text is only typed into the app that was frontmost when the key was pressed. If
  another app has come to the front by delivery time, nothing is typed; the text stays
  on the clipboard and in history and the HUD says so.
- history.json and vocabulary.json are written with user-only permissions (0600 in a
  0700 folder).
- The Parakeet model download is pinned to huggingface.co; FluidAudio is pinned to an
  exact version.
- `make dmg` refuses to build a shareable image without a Developer ID certificate.
- `make bump` edits only the two version values in Info.plist instead of rewriting
  the file; `make release` trims the leading blank line from the release notes.

### Fixed

- Intermittent crashes on key press and when the HUD appeared, introduced by the
  Swift 6.4 toolchain's runtime actor-isolation checks misfiring in framework
  callbacks. Those checks are now compiled out (static checking remains), the hotkey
  tap callback lives outside the main-actor class, animation closures are Sendable,
  and the build targets the SDK matching the running macOS.
- The "capture started" log line now names the input device, so a Bluetooth headset
  silently taking over the microphone is visible at a glance.
- The app no longer freezes when the microphone is switching devices (AirPods
  connecting or dropping) at the moment the key is pressed. Capture runs off the main
  thread with a fresh audio engine per utterance, and a start that takes longer than
  four seconds shows "Microphone did not start" instead of hanging.
- `make test` works again on Swift 6.4 Command Line Tools, which moved the Swift
  Testing macro plugin.

## [0.2.0] - 2026-09-17

### Added

- The LICENSE and third-party notices now travel inside the app bundle, and the
  bundle carries a copyright string.
- This changelog, and `make bump` / `make release` so every release is versioned,
  notarized, tagged and published in one guarded step.

## [0.1.0] - 2026-09-17

First public release.

### Added

- Push-to-talk dictation: hold Right ⌥ (or fn), speak, release; the text is typed
  into the focused app via Accessibility insert with paste as fallback.
- Session mode: tap the key to open a panel that listens until Done; the result goes
  to the clipboard and stays editable in the panel.
- Two on-device engines behind one protocol: Apple `SpeechAnalyzer` (English, German,
  streaming) and NVIDIA Parakeet TDT v3 via FluidAudio (Russian, auto-detect, 25
  languages). Engine and language are selectable from the menu bar.
- Formatting pipeline: rule-based cleanup, deterministic vocabulary mapping, and an
  optional polish step using Apple's on-device Foundation Models when Apple
  Intelligence is enabled.
- Vocabulary: canonical terms with known misrecognitions, passed to the Apple
  recognizer as hints and applied as exact word-boundary replacements. Editable in a
  window and as `vocabulary.json`; the file is re-read before every utterance and a
  broken file never wipes the list.
- Learning from edits: correcting a transcript in History or the session panel offers
  each word-level substitution once as a vocabulary suggestion.
- Validation warnings in the Vocabulary window for single-word variants found in the
  system dictionary, which would corrupt real uses of that word.
- History window with the last 500 transcripts, each showing which vocabulary
  corrections fired.
- Capsule HUD with level meter and live text; never takes focus from the target app.
- Menu bar icon, generated from `Resources/Icon/MakeIcon.swift`.
- Build system: `make install` for development, `make dmg` for a release build with a
  timestamped Developer ID signature, `make notarize` to notarize and staple the DMG.
- MIT license and third-party notices (FluidAudio, Parakeet) in the repository.

[Unreleased]: https://github.com/mzogot/Wisperfy/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mzogot/Wisperfy/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mzogot/Wisperfy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mzogot/Wisperfy/releases/tag/v0.1.0
