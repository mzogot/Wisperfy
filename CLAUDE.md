# CLAUDE.md

Guidance for Claude Code when working in this repository. Read it before changing anything.

## Memory and Lessons

Three layers, each with one job. Do not duplicate content between them.

| Layer | Holds | When to write |
|---|---|---|
| `CLAUDE.md` (this file) | rules, structure, the load-bearing decisions | when a rule or the layout changes |
| `docs/LESSONS.md` | symptom → cause → rule, one entry per hard-won lesson | after any bug that took more than a few minutes, or a "simplification" that broke something |
| `docs/CHECKLIST.md` | manual tests that need a signed bundle and a person | when a feature adds behaviour that `make test` cannot cover |
| Claude auto-memory (`~/.claude/projects/…/memory/`) | facts about this machine and the user, not the code | cross-session environment facts only |

Read `docs/LESSONS.md` before debugging anything in an area it covers. When a session
ends with a lesson, add it there in the same commit as the fix.

## Overview

Wisperfy is a push-to-talk dictation app for macOS, a local and private Wispr Flow clone.
Hold a key, speak, release: text is typed into the focused app. Tap the key instead: a
session panel listens until Done and puts the result on the clipboard. Everything runs
on-device with no cloud, no account and no cost. macOS only; Windows is out of scope.

## Project Structure

```
Wisperfy/
├── Package.swift              SwiftPM manifest, macOS 26, Swift 6 strict concurrency
├── Makefile                   build → bundle → sign → install (the only supported build path)
├── Resources/                 Info.plist, entitlements, AppIcon.icns (regenerate: `make icon`
│                              from Icon/MakeIcon.swift; edit the script, not the .icns)
├── docs/                      LESSONS.md (lessons learned), CHECKLIST.md (manual tests)
├── Tests/WisperfyTests/       Swift Testing: formatters, vocabulary, correction diffs, polish
└── Sources/Wisperfy/
    ├── WisperfyApp.swift      @main, MenuBarExtra, AppDelegate
    ├── Core/                  DictationController, HotkeyMonitor, AudioCapture, TextInjector
    ├── Transcription/         TranscriptionEngine protocol, AppleSpeechEngine, ParakeetEngine
    ├── Formatting/            TextFormatter protocol, FormattingPipeline, RuleBasedFormatter,
    │                          VocabularyFormatter, PolishFormatter (Foundation Models)
    ├── UI/                    HUDPanel + HUDView (push to talk), SessionPanel + SessionView,
    │                          HistoryWindow + HistoryView (past transcripts, editable),
    │                          VocabularyWindow + VocabularyView, CorrectionReviewView
    └── Support/               Settings, Permissions, Log, Timeout, TranscriptHistory, Vocabulary
```

## File Structure

- **Core/DictationController.swift**: the state machine. `idle → starting → listening →
  finishing → idle`, two modes (`pushToTalk`, `session`). Everything is wired here.
- **Core/HotkeyMonitor.swift**: `CGEventTap` on modifier `flagsChanged`. Needs Accessibility.
- **Core/AudioCapture.swift**: `AVAudioEngine` tap, converts to the engine's format, RMS level.
- **Core/TextInjector.swift**: Accessibility insert verified by caret movement, else paste.
- **Transcription/**: two engines behind one protocol. Apple = streaming, en/de, takes the
  vocabulary as contextual hints. Parakeet (FluidAudio, CoreML) = batch with periodic
  partials, 25 languages incl. Russian, auto-detect, no vocabulary hook.
- **Formatting/**: `FormattingPipeline` runs rules → vocabulary → optional polish →
  vocabulary again. `PolishFormatter` is Apple's on-device Foundation Models model with
  the glossary in its instructions; bounded, validated, falls back to its input.
- **Support/Vocabulary.swift**: canonical terms + known misrecognitions in
  `~/Library/Application Support/Wisperfy/vocabulary.json`. Also holds `WordDiff`, which
  turns a user's edit into `CorrectionSuggestion`s (word-level substitutions only).
- **UI/**: the HUD is a non-activating, never-key panel. The session panel can become key
  but is still non-activating. The History window is a normal titled window; it calls
  `NSApp.activate()` because an `LSUIElement` app otherwise opens it behind everything.
- **Support/TranscriptHistory.swift**: every finished transcript, newest first, as JSON in
  `~/Library/Application Support/Wisperfy/history.json`. Capped at 500 entries.
- **Support/Timeout.swift**: `awaitWithTimeout` for engine calls that may never return.

## Setup & Installation

```bash
make install            # build, bundle, sign with Developer ID, copy to /Applications, launch
make logs               # live log stream (subsystem com.wisperfy.app)
make reset-permissions  # resets ONLY this app's Accessibility + Microphone rows
```

Two permissions are mandatory and cannot be granted silently: Accessibility (event tap,
AX insert) and Microphone. The app polls for the Accessibility grant, so no relaunch.

## Architecture

```
key ─► HotkeyMonitor ─► DictationController ─┬─► AudioCapture ──ordered chunks──► TranscriptionEngine
                                             ├─► HUDPanel / SessionPanel                 │  ▲ hints
                                             └─────────────────────────────── FormattingPipeline
                                        both:         clipboard + TranscriptHistory ◄───┤  ▲ terms
                                        push to talk: TextInjector ─► focused app        │  │
                                        session:      SessionPanel ◄─────────────────────┘  │
                                        edits in History / SessionPanel ─► suggestions ─► Vocabulary
```

Decisions that look odd and are load-bearing:

- **The HUD must never become key.** If it took focus, the target text field would lose
  it and there would be nothing to type into. `canBecomeKey` stays `false`.
- **The hotkey is a CGEventTap, not NSEvent.** Only a tap sees fn and tells Right ⌥ from
  Left ⌥ (device flag bits `0x40` / `0x10`). Do not "simplify" to `addGlobalMonitor`.
- **Audio ordering is explicit.** One task drains one `AsyncStream` with sequential
  awaits. A `Task` per buffer silently scrambles transcripts.
- **Tap buffers are copied, never borrowed.** `AVAudioEngine` recycles them on return.
- **The audio tap closure is `@Sendable`.** Without it Swift infers main-actor isolation
  and traps on the audio thread. This crashed the app once.
- **AX insert success is not trusted.** Electron, Chrome and terminals accept the write
  and drop it. Only a moved caret counts; otherwise fall back to paste.
- **The final text always lands on the clipboard and in history, in both modes.** The
  paste fallback does not restore the previous clipboard: a swallowed paste must still
  be one ⌘V away.
- **Engine calls are bounded.** `finalizeAndFinishThroughEndOfInput` and the results
  stream have hung with near-zero audio. Keep the `awaitWithTimeout` wrappers.
- **Tap vs hold** is a 350 ms threshold in the controller. The pipeline is already
  running when a tap is recognised; conversion is just a mode change.
- **Signing is functional, not cosmetic.** macOS keys TCC grants to the code signature.
  The Makefile auto-detects a Developer ID; never replace it with `--sign -`.
- **The vocabulary learns only from explicit edits.** Text typed into other apps is
  invisible to us, so corrections come from editing a transcript in History or the
  session panel. Each substitution is offered once; nothing is auto-learned.
- **Deterministic mapping is exact, never fuzzy.** A variant like "cloud" → "Claude"
  would corrupt every real mention of the cloud, so the Vocabulary window warns when a
  single-word variant is in the system dictionary. The one liberty taken: between the
  words of a variant any run of whitespace or hyphens matches, including none, so
  "cloud code" also catches "CloudCode" and "Cloud-Code". The whole pattern is still
  required on word boundaries. Fuzzy, context-aware fixes are the polish model's job.
- **vocabulary.json is hand-editable.** Only `canonical` is required per entry. The
  file is re-read (one stat) before every utterance and when the window opens. If it
  fails to decode, nothing is written until it loads again, so a typo never wipes the
  list. Hints to the Apple recognizer are capped (`maximumHintTerms`), most-used first.
- **History records what the vocabulary changed.** Each `TranscriptEntry` carries the
  `AppliedCorrection`s that fired, shown under the transcript, so the user can tell
  whether an entry is doing anything.
- **Polish never blocks delivery.** It runs only if Apple Intelligence is on and the
  language is supported (no Russian), inside `valueWithTimeout`, and a result that is
  empty or far off the input length is discarded. Rules and vocabulary run regardless.

## Core Principles

1. **On-device only.** No network calls except one-time model downloads. Never add a
   cloud transcription or cloud LLM path by default.
2. **Minimal, modern UI.** One capsule HUD, one session panel. Every literal lives in
   `HUDStyle` / `SessionStyle`; views contain no raw numbers.
3. **Protocols are the swap points.** New engines implement `TranscriptionEngine`; new
   cleanup tiers implement `TextFormatter`. `DictationController` should not change.
4. **Swift 6 strict concurrency, no warnings.** Fix isolation properly, not with
   `assumeIsolated` (it asserts, it does not check).
5. **Reference, don't copy.** `per-simmons/murmur-youtube` guided the design but has no
   license. Write our own code.

## Tech Stack

- Swift 6.4, SwiftUI + AppKit, SwiftPM (`swift-tools-version: 6.2`), macOS 26+
- Apple `SpeechAnalyzer` / `SpeechTranscriber` (Speech.framework, macOS 26)
- FluidAudio ≥ 0.15.7 for Parakeet TDT 0.6B v3 (CoreML, ~500 MB, cached in
  `~/Library/Application Support/FluidAudio/Models/`)
- `os.Logger` per category; `Observation` for state

## Development Workflow

1. Build and run with `make install`; `swift build` alone produces a binary that cannot
   get permissions. Build products live in `~/Library/Caches/WisperfyBuild`, never in-tree.
2. Verify with `make logs`. A full run logs `listening → finishing → capture stopped →
   inserted|pasted|copied`. A crash leaves a report in `~/Library/Logs/DiagnosticReports`.
3. Synthetic key events (`CGEvent` with `.flagsChanged`) exercise the state machine but
   produce no speech; real transcription needs a human at the microphone.
4. Toolchain constraint: this Mac has Command Line Tools only. The SwiftUI macro plugin is
   missing, so `@State` does not compile. Keep view state in `@Observable` objects and use
   phase animators. `@Observable`, `@Bindable`, `@NSApplicationDelegateAdaptor` are fine.

## Testing Requirements

`make test` runs the Swift Testing target (works with Command Line Tools alone; the
`@Test` / `#expect` macros compile). It covers `RuleBasedFormatter`, `VocabularyFormatter`,
`WordDiff` and `Vocabulary` learning; the `PolishFormatter` tests self-skip when Apple
Intelligence is off. Anything touching TCC, the event tap or audio needs a signed bundle
and a person: that is `docs/CHECKLIST.md`, not CI. Run the relevant section after
touching an area.

## Error Handling

- Engine and capture errors surface as `State.error(message)`. The HUD hides after 2.5 s;
  the session panel shows the message until closed.
- Log with the matching `Log.*` category and `privacy: .public` for non-user data.
  Transcripts are `.private`.
- Never wipe permissions globally. `tccutil reset Accessibility` without a bundle ID
  resets every app on the machine.

## Common Commands

```bash
make install                 # the normal loop
make test                    # unit tests for the pure pieces
make run                     # run from the build cache without installing
make clean                   # remove build cache and staged bundle
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.wisperfy.app"' --style compact
```
