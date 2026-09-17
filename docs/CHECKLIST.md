# Manual Test Checklist

Everything here needs a signed bundle (`make install`) and a person at the microphone.
It is the counterpart of `make test`, which covers only pure logic. Run the relevant
section after touching the area, and the whole list before calling a milestone done.
Watch `make logs` in a second terminal throughout.

## Permissions
- [ ] Fresh install (`make reset-permissions`, `make install`): Accessibility prompt
      appears; after granting, the log shows `armed on …` without a relaunch.
- [ ] First push to talk: Microphone prompt appears once; dictation works right after.
- [ ] Rebuild and reinstall: both grants survive (no new prompts).

## Push to talk
- [ ] Hold key, speak a sentence, release: HUD shows live text, then the text appears
      in the focused field. Log: `listening → finishing → capture stopped → inserted`.
- [ ] Same into Chrome, an Electron app and Terminal: log shows `pasted` where AX
      insert is dropped, and the text still arrives.
- [ ] Release with no speech: HUD hides quickly, nothing is typed, nothing in history.
- [ ] Key released while still `starting`: the utterance still finishes cleanly.
- [ ] Text is on the clipboard after every run, even when insert succeeded.

## Session
- [ ] Tap the key: session panel opens at the bottom, live text streams.
- [ ] Tap again or press Return: Done; text stays in the panel and on the clipboard.
- [ ] Panel never steals focus from the app behind it; clicking a button in it does
      not bring Wisperfy to the front.
- [ ] Escape closes the panel; a running session is cancelled without output.
- [ ] Edit the finished transcript in the panel, press Copy: the history entry is
      updated and word substitutions are offered in the strip.

## Engines and languages
- [ ] English and German on Apple: live partials, correct locale in the log.
- [ ] Russian: routed to Parakeet; first run downloads the model with the hint shown.
- [ ] Auto-detect: Parakeet, correct language picked for a German and a Russian sentence.
- [ ] Engine forced to Parakeet for English: works, periodic partials in a session.

## Vocabulary and learning
- [ ] Vocabulary… window opens in front, terms and variants editable, ⌘N adds a row,
      trailing comma can be typed in the variants field.
- [ ] Add "Claude Code" with variant "clot code": a dictation containing the variant
      is corrected; the hit count increases.
- [ ] With Apple engine: log shows `context set with N terms`; the term is recognised
      more often without the mapping firing.
- [ ] History → Edit → change a word → Save: suggestion strip appears; Add creates or
      extends the entry; Skip removes it; selecting another entry clears the strip.
- [ ] Case-only or punctuation-only edits produce no suggestion.

## Polish (needs Apple Intelligence on)
- [ ] Menu toggle enabled, no reason line shown.
- [ ] Log shows `polished in …s` for a sentence of four words or more; punctuation
      improved, wording unchanged.
- [ ] A dictated question is not answered.
- [ ] Russian dictation logs `skipped: … not supported` and still delivers text.
- [ ] Toggle off: no `polish` log lines, delivery unchanged.

## Security and privacy
- [ ] Focus a password field (System Settings ▸ Users & Groups ▸ change password, or a
      browser login form), hold the key, say a word, release: HUD shows "Listening,
      private field…" and never the words; the field receives the text; log shows
      `private field focused` and `typed privately`; nothing on the clipboard, no
      history entry, no `polish` lines.
- [ ] Same in Terminal at a `sudo` prompt: not detected (expected); text is typed the
      normal way and does land in history.
- [ ] Hold the key, speak, and ⌘-Tab to another app before releasing: nothing is typed
      into the second app; HUD shows "Focus moved. Text is on the clipboard."; log
      shows `front app changed`; history has the entry.
- [ ] `ls -l ~/Library/Application\ Support/Wisperfy/`: folder `drwx------`, both
      files `-rw-------` after a dictation and a vocabulary edit.
- [ ] Toggle "Hide from Clipboard Managers" on, dictate, check a clipboard manager
      (Maccy, Raycast): the transcript is not in its history; ⌘V still pastes it.
      Toggle off: the next transcript appears in the manager again.
- [ ] `make logs` during a full run: no line contains dictated words.

## Menu
- [ ] About Wisperfy: the standard About panel opens in front and shows the version
      from Info.plist and the build; a dev build reads `(n dev <sha>+)`, a release
      build the plain number matching `## [x.y.z]` at the top of CHANGELOG.md.

## Robustness
- [ ] Tap with almost no audio: finishes within the timeout, log may show
      `finalize timed out`, app stays responsive.
- [ ] Microphone picker: with AirPods connected and "Built-in Microphone" selected,
      dictation captures from the MacBook mic (log says so) and text arrives. Select
      the AirPods in the picker: log names them and dictation works through them.
      Disconnect them: picker shows "Saved microphone (not connected)" and capture
      falls back to the system default with a log line.
- [ ] Put AirPods in (or connect any Bluetooth headset) and press the key within a
      second or two: either dictation works from the headset, or the HUD shows
      "Microphone did not start" and the next press works. The app never freezes.
- [ ] Take the AirPods out mid-utterance: the utterance ends without a freeze; the
      log shows `capture stopped` within a few seconds.
- [ ] Quit and relaunch: history and vocabulary persist; window frames restored.
- [ ] No crash report in `~/Library/Logs/DiagnosticReports` after the run.
