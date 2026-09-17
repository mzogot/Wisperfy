# Lessons Learned

Things that cost a debugging round once and must not cost one again. Each entry is
a symptom, its cause, and the rule that follows. Grouped by area; newest entries at
the top of each group. Add an entry whenever a bug took more than a few minutes to
understand, or when a "simplification" turned out to be load-bearing.

Entry template:

```
### Short title
- **Seen:** YYYY-MM-DD, what it looked like
- **Cause:** why it happened
- **Rule:** what to do (or never do) from now on
- **Where:** file or command
```

---

## Concurrency (Swift 6 strict)

### Audio tap closure traps on the audio thread
- **Seen:** 2026-09-16, crash `dispatch_assert_queue_fail` under
  `AudioCapture.start` in the `AVAudioNodeTap` callback (crash report in
  `~/Library/Logs/DiagnosticReports`).
- **Cause:** a closure formed inside a `@MainActor` method is inferred main-actor
  isolated. `AVAudioEngine` calls it on its own realtime thread and the runtime
  isolation check traps.
- **Rule:** the `installTap` closure and anything it calls are `@Sendable`. Never let
  the compiler infer isolation for a callback that a framework calls off-main.
- **Where:** `Core/AudioCapture.swift`

### Isolation check crashes in framework callbacks
- **Seen:** 2026-09-16 twice and 2026-09-17 three times: segfault inside the runtime's
  "is this the main executor" check, once at the entry of the HUD status dot's
  `phaseAnimator` closure and four times at the entry of the `CGEventTap` callback.
  Same bad address every time. The first press after launch worked; a later one
  crashed. Removing `assumeIsolated` did not help, and neither did building against
  the OS-matching SDK: the crash moved to the compiler's own check at closure entry.
- **Cause:** the Swift 6.4 compiler (Command Line Tools 27.0, installed 2026-09-10)
  emits a runtime isolation check at the entry of nearly every closure formed in an
  actor-isolated context, including plain `filter` closures. `otool -tV` on the binary
  showed over a hundred call sites. In ordinary actor code the check takes its fast
  path. A closure invoked from a raw run-loop source (the event tap) or from SwiftUI's
  animation machinery has no task context, and there the OS 26.6 runtime's slow path
  dereferences a bad executor pointer. Every crash came after the toolchain update.
- **Rule:** three layers. (1) `Package.swift` passes `-disable-dynamic-actor-isolation`
  for the app target; Swift 6 language mode still checks isolation statically, and the
  binary now has no check sites (verify with
  `otool -tV <binary> | grep -c swift_task_isCurrentExecutor`). (2) Callbacks a
  framework invokes are never closures formed inside a `@MainActor` type: the tap
  callback is a file-scope function, the audio tap and animation closures are
  `@Sendable`, and they hop to the main actor with a `Task`. (3) The Makefile builds
  against the newest SDK not newer than the running OS.
- **Where:** `Package.swift`, `Makefile`, `Core/HotkeyMonitor.swift`,
  `UI/HUDView.swift`, `UI/HUDPanel.swift`, `UI/SessionPanel.swift`

### The app froze starting the microphone while AirPods reconnected
- **Seen:** 2026-09-17, third push-to-talk in a row: HUD stuck, hotkey dead, 45 % CPU.
  `sample` showed the main thread inside `AVAudioEngine.prepare()` waiting on the
  engine's IO-unit queue, which was spinning on a property change; the system log had
  thousands of "agg device … sub-device #channels = 0" lines. coreaudiod had switched
  the default input to the AirPods two seconds earlier.
- **Cause:** `AudioCapture` was main-actor code calling `prepare()`/`start()` on the
  main thread, and it reused one `AVAudioEngine`, whose IO unit stayed bound to the
  device that was in transition.
- **Rule:** `AudioCapture` is an actor and creates a fresh `AVAudioEngine` per capture.
  The controller wraps start in `valueWithTimeout` (4 s) and stop in `awaitWithTimeout`
  (2 s); on a start timeout it abandons that instance, tells it to stop whenever it
  wakes up, and creates a new one, so the next utterance works. The user sees
  "Microphone did not start" instead of a frozen app. Nothing in the app calls
  CoreAudio from the main thread anymore.
- **Where:** `Core/AudioCapture.swift`, `Core/DictationController.swift`
  (`startCapture`, `stopCapture`)

### A Task per audio buffer scrambles transcripts
- **Seen:** 2026-09-16, words out of order in the transcript, no error anywhere.
- **Cause:** tasks are not FIFO. Chunks fed from separate tasks reach the engine in
  arbitrary order.
- **Rule:** one task drains one `AsyncStream` with sequential awaits. Ordering is a
  property of the code shape, not of the data.
- **Where:** `Core/DictationController.swift`, `feedTask`

### Tap buffers are recycled
- **Seen:** 2026-09-16, silent corruption when buffers were held past the callback.
- **Cause:** `AVAudioEngine` reuses the tap buffer once the callback returns.
- **Rule:** copy the buffer before it crosses a thread or a stream.
- **Where:** `Core/AudioCapture.swift`

### `assumeIsolated` is not a fix
- **Seen:** 2026-09-16, considered as a shortcut for isolation errors.
- **Cause:** it asserts at runtime instead of checking; it trades a compile error for a
  crash.
- **Rule:** fix isolation properly: actor, `@Sendable`, or `MainActor.run`.

## Permissions and signing

### Ad-hoc signing silently loses Accessibility and Microphone grants
- **Seen:** 2026-09-16, toggles on in System Settings, event tap still refused.
- **Cause:** TCC keys grants to the code signature. `--sign -` produces a new
  signature every build, so every build is a new app to TCC.
- **Rule:** the Makefile signs with the Developer ID it finds. Never replace it with
  ad-hoc. Install to `/Applications` so the path is stable too.
- **Where:** `Makefile`

### `swift build` binaries cannot get permissions
- **Seen:** 2026-09-16, bare binary never received the Accessibility prompt.
- **Cause:** TCC needs a bundle identity; a bare SwiftPM executable has none.
- **Rule:** `make install` is the only supported run path.

### `tccutil reset` without a bundle ID wipes every app
- **Seen:** 2026-09-16, nearly ran it while debugging.
- **Rule:** always `tccutil reset <Service> com.wisperfy.app`. `make reset-permissions`
  does exactly that and nothing else.

### AX insert reports success and drops the text
- **Seen:** 2026-09-16, "inserted" in the log, nothing in Chrome, Electron apps and
  terminals.
- **Cause:** those apps accept the `kAXSelectedTextAttribute` write and ignore it.
- **Rule:** only a moved caret counts as inserted; otherwise paste. And the text is on
  the clipboard before any insert attempt, so a swallowed paste is one ⌘V away.
- **Where:** `Core/TextInjector.swift`

## Speech engines

### `finalizeAndFinishThroughEndOfInput` can hang forever
- **Seen:** 2026-09-16, app stuck in `finishing` after a tap with almost no audio.
- **Cause:** Apple's analyzer never returns from finalize when it received near-zero
  audio; the results stream does not end either.
- **Rule:** every engine call that may not return goes through `awaitWithTimeout` or
  `valueWithTimeout`, followed by `cancelAndFinishNow`.
- **Where:** `Transcription/AppleSpeechEngine.swift`, `Support/Timeout.swift`

### `supportedLocale(equivalentTo:)` lies
- **Seen:** 2026-09-16, `ru-RU` returned as supported, then failed to start.
- **Cause:** the helper maps to a nearby locale without checking the real list.
- **Rule:** check against `SpeechTranscriber.supportedLocales` directly. Russian goes
  to Parakeet.

### Parakeet has no vocabulary hook
- **Seen:** 2026-09-16, while adding recognizer hints.
- **Cause:** FluidAudio's `AsrManager` exposes no contextual biasing.
- **Rule:** only Apple's engine gets `AnalysisContext.contextualStrings`. Parakeet
  output relies on the mapping table and the polish tier.

## Formatting and the vocabulary

### A single common word as a variant corrupts real text
- **Seen:** 2026-09-16, design review of the mapping table.
- **Cause:** "cloud" → "Claude" would rewrite every genuine mention of the cloud.
- **Rule:** the deterministic pass is exact and word-bounded, never fuzzy. Multi-word
  or unambiguous variants only. Context-dependent fixes belong to the polish model.
- **Where:** `Formatting/VocabularyFormatter.swift`

### The polish model answers questions in the dictation
- **Seen:** 2026-09-16, anticipated while writing the prompt; a small model treats
  "what is the capital of France" as a request.
- **Rule:** instructions say the text is dictation, not a request; the output is
  validated against the input length and discarded when off. The test
  `doesNotAnswerQuestionsInTheText` guards it (runs only with Apple Intelligence on).
- **Where:** `Formatting/PolishFormatter.swift`

### Apple Intelligence supports German and English, not Russian
- **Seen:** 2026-09-16, `SystemLanguageModel.default.supportsLocale(ru)` is false.
- **Rule:** the polish tier checks `supportsLocale` per utterance and skips silently.
  Language is detected with `NLLanguageRecognizer` when the setting is auto.

## Toolchain (Command Line Tools only, no Xcode)

### `@State` does not compile
- **Seen:** 2026-09-16, "plugin for module 'SwiftUIMacros' not found".
- **Cause:** the CLT ship the Observation macros but not the SwiftUI ones.
- **Rule:** view state lives in `@Observable` objects passed into the view; animations
  use phase animators. `@Bindable` and `@NSApplicationDelegateAdaptor` are fine.

### Swift Testing does work with the CLT
- **Seen:** 2026-09-16, `@Test` and `#expect` compiled and ran on the first try.
- **Rule:** pure logic gets a test in `Tests/WisperfyTests`. Run with `make test`.
  An async test that uses `#require` must be declared `throws`.

### Swift 6.4 CLT: "plugin for module 'TestingMacros' not found"
- **Seen:** 2026-09-16 and again 2026-09-17, every `@Suite` / `@Test` failed to compile
  whenever the test module was built fresh (new test file, sources changed).
- **Cause:** the Testing macro plugin lives in `usr/lib/swift/host/plugins/testing/`, a
  subfolder the build does not always search (`plugins/` itself holds the Observation
  macros, which is why the app keeps building). Once the module has been compiled with
  the path given, plain `swift test` passes again on the same scratch, which made it
  look like stale state.
- **Rule:** `make test` passes `-Xswiftc -plugin-path -Xswiftc <that folder>` when the
  folder exists, so the first run works too. Do not switch to `--build-system native`:
  it then loses the Testing framework search path as well and needs three more flags.
- **Where:** `Makefile` (`TESTING_PLUGINS`)

### Foundation Models initialiser label differs between SDKs
- **Seen:** 2026-09-16, warning on `GenerationOptions(sampling:)` (that was the 27.0
  SDK deprecating it); 2026-09-17, `samplingMode:` does not exist in the 26.5 SDK.
- **Rule:** the project builds against the OS-matching SDK (see above), so the label is
  `sampling:`. Switch to `samplingMode:` only when the minimum OS becomes 27. The project builds with
  zero code warnings; keep it that way.

### Apple Intelligence is off on the development Mac
- **Seen:** 2026-09-16, `availability` = `appleIntelligenceNotEnabled`.
- **Rule:** the polish tier and its live tests are unverified until it is enabled in
  System Settings. The menu shows the reason. Do not report polish as tested.

## Build and install

### Build products must not live under ~/Documents
- **Seen:** 2026-09-16, sync engine touching files mid-compile and stamping xattrs on
  a freshly signed bundle.
- **Rule:** scratch path and staged bundle live in `~/Library/Caches/WisperfyBuild`.
  `xattr -cr` before signing.
- **Where:** `Makefile`

### `make install` can fail to relaunch with error -600
- **Seen:** 2026-09-16, `_LSOpenURLsWithCompletionHandler() failed with error -600`
  right after `pkill`, app not running afterwards.
- **Cause:** Launch Services still saw the old process shutting down.
- **Rule:** if the app is not running after `make install`, run
  `open /Applications/Wisperfy.app` again. Check `pgrep -x Wisperfy`.

### An `LSUIElement` app opens normal windows behind everything
- **Seen:** 2026-09-16, History window appeared but had no focus.
- **Cause:** accessory apps are not activated when they show a window.
- **Rule:** regular windows (History, Vocabulary) call `NSApp.activate()` before
  `makeKeyAndOrderFront`. The HUD and session panel must never do this.

## SwiftUI patterns without `@State`

### Parsing a text field on every keystroke eats what the user is typing
- **Seen:** 2026-09-16, the variants field could not accept a trailing comma.
- **Cause:** a binding that parses "a, " into ["a"] and re-renders "a" on each
  keystroke.
- **Rule:** keep a per-row draft string in the view model (`VocabularyViewModel.drafts`)
  and write the parsed value to the model beside it. Clear drafts on window close.
- **Where:** `UI/VocabularyView.swift`
