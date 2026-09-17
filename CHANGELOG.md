# Changelog

All notable changes to Wisperfy are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/): while the major version is 0, a minor
bump may change behaviour, a patch bump only fixes.

Every release starts by moving the Unreleased section into a new version heading
(`make bump VERSION=x.y.z`), then `make release` builds, notarizes, tags and publishes.

## [Unreleased]

### Changed

- `make bump` edits only the two version values in Info.plist instead of rewriting
  the file; `make release` trims the leading blank line from the release notes.

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

[Unreleased]: https://github.com/mzogot/Wisperfy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mzogot/Wisperfy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mzogot/Wisperfy/releases/tag/v0.1.0
