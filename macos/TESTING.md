# Testing M0 by hand

Everything in `macos/` that a compiler or a unit test can check is checked.
What remains needs a person at a real keyboard with a real microphone, and it
is the part that decides whether M0 works at all.

Read this list before you start. Each test names **what should happen** and
**what to write down if it doesn't**, because most of these fail silently and
"it didn't work" is not a report anyone can act on.

## Setup, once

```sh
Tools/setup-testing.sh
```

It links the `dictate` helper where the app looks for it, writes
`~/.cochlea/config.json` pointing at a model you have, then builds, signs and
unquarantines the bundle. It is idempotent and it prints what is missing rather
than failing obscurely, so re-run it after any Swift change — that rebuild and
re-sign is the whole point.

Two things it does that are not obvious:

- **Ad-hoc signing is not cosmetic.** TCC keys an unsigned bundle by path and
  re-prompts unpredictably across rebuilds. With a stable identifier you can
  also reset permissions cleanly when a rebuild confuses it:

  ```sh
  tccutil reset Accessibility com.cochlea.app
  tccutil reset Microphone com.cochlea.app
  ```

- **It does not put `dictate` on `PATH`, it links it into
  `/opt/homebrew/bin`.** An app launched from Finder does not inherit the
  shell's `PATH`, so an app that trusted it would work from a terminal and fail
  on double-click.

It defaults to `whisper-small`, which meets M0's latency budget on an 8 GB M2
where `large-v3-turbo` does not (D6). To test the other one:

```sh
COCHLEA_TEST_MODEL=whisper-large-v3-turbo Tools/setup-testing.sh
```

(that model has to be downloaded first, and the config is only written when
absent — delete `~/.cochlea/config.json` to have it rewritten).

## Watching what it does

Run it from a terminal and the log is right there:

```sh
./build/cochlea.app/Contents/MacOS/cochlea
```

Launch it from Finder — which is the realistic case, and the one where `PATH`
is not inherited — and read the log instead:

```sh
log stream --predicate 'subsystem == "com.cochlea.app"' --style compact
```

A healthy launch looks like this:

```
[config] loaded /Users/you/.cochlea/config.json
[start]  transcriber: whisper-small
[start]  model dir:   /Users/you/.cochlea/models/whisper-small
[start]  microphone:  granted
[start]  accessibility: not yet granted
[warmup] model resident after 2513 ms
```

If `[warmup]` says *failed*, stop: the helper or the model is wrong, and
nothing below will work. The message names which.

---

## Already answered

First hand-test, Apple M2 / macOS 26.6.1 / `whisper-small`. Re-run these on
different hardware — one machine is one data point — but they are no longer
open questions.

| | Result |
|---|---|
| **T1** hotkey key-up | **Passes.** `RegisterEventHotKey` delivers `kEventHotKeyReleased`. Push-to-talk works as built and the `NSEvent` fallback is not needed. |
| **T2** permissions | **Passes.** Nothing prompts at launch; both prompts arrive on the first press. |
| **T3** injection | **Passes.** TextEdit, browser and VS Code, nothing executed. |
| **T4** long text | **Passes.** A 28.6 s paragraph, 398 characters, no truncation — the 16-unit chunking is fine. |
| **T7** latency | **Passes.** 383–441 ms warm, against a 1000 ms budget. A 28.6 s utterance cost 1016 ms; Whisper pads to a 30 s window, so that is one window's price, not a per-second one. |
| **T5** VAD / mic closes | **Passes after a fix.** Silence now ends the utterance mid-hold and the text is typed before release. See below. |
| **T6** device change | **Passes after a fix.** Switching the input device to AirPods mid-session is detected, the graph is rebuilt on the next press, and dictation continues. Previously it hung the app. |

Every core test above now passes on this machine. **T8 through T12 have never
been run** — T9 through T12 cover behaviour that did not exist when the first
hand-test happened.

Two observations that are not bugs but are worth knowing:

- **Capture is now essentially lossless.** With the drain, a 3.374 s hold
  captured 3.37 s. Before it lost about 170 ms.
- **`whisper-small` is noticeably weaker on an AirPods microphone.** The same
  sentence went from "The deployment failed at midnight" on the built-in mic to
  "The deployment fell at midnight" over AirPods. That is narrowband audio meeting
  the smallest model in the catalogue, not a capture fault — the sample counts
  show the audio arrived intact. It is the clearest argument yet for D6's
  unfinished business: one default cannot serve every microphone either, and
  a user on a headset may want `large-v3-turbo` despite the latency.
  The noise floor on AirPods measured 0.0019 against 0.0192 built-in, where the
  absolute floor correctly clamped the threshold to 0.012.

Things that test found, all fixed:

- **The microphone opened 2084 ms after key-down**, so the first two seconds of
  the utterance were spoken into a microphone that was not open. The bulk was
  the one-time Accessibility grant; the remainder was the first `inputNode`
  access at ~190–240 ms, now paid at launch by `AudioCapture.prewarm()`. After
  both: 366 ms on the first press of a session, 114 ms after. Watch this number
  on other machines — anything approaching a second clips a word.
- **The VAD never fired.** Holding silent for four seconds did not end the
  utterance. Measured on the spot: that room idles at 0.0166–0.0386 RMS against
  a fixed threshold of 0.012, so 100% of silence counted as speech, trailing
  silence never accumulated, and the accidental-tap guard was broken by the
  same fact. The threshold is now relative to a measured noise floor, with a
  ceiling — without one, a user who presses and speaks immediately seeds the
  floor with speech and loses the whole utterance, which is worse than the bug
  being fixed. The hangover went from 0.6 s to 1.5 s, since 0.6 s is shorter
  than a person pausing to think.
- **The last 85 ms of every utterance was being thrown away.** Two presses
  reported byte-identical sample counts, which should be impossible for
  different hold durations. Cause: `installTap`'s `bufferSize` is a hint the
  engine ignores — it delivers 100 ms buffers whatever you ask for (measured at
  512, 1024 and 4096, all identical) — so capture is quantised to 100 ms and
  `stop()` discards the partially filled buffer. Two holds in the same bucket
  therefore produce the same count. Releasing the key now waits one buffer
  period first: a 2.00 s hold went from 1.94 s of audio to 2.03 s.
- **Connecting AirPods stopped dictation completely (T6).** `AVAudioEngine`
  binds to the input device it was built against, and nothing observed
  `AVAudioEngineConfigurationChange`, so the engine held a reference to
  hardware that no longer existed and `start()` blocked forever — on the main
  actor, which took the app with it. The tell was three `[hotkey] key down`
  lines with no `[audio]`, no `[capture]` and no `[timing]` after them: that
  last one is in a `defer`, so its absence means the function never returned.
  The graph is now rebuilt when the device changes, and an early return logs
  instead of vanishing.
- **An English sentence transcribed as Malay.** Whisper detects language from
  the first window, and a clipped window is read as whatever it most resembles
  — then the *whole* window is mistranscribed, not just the missing part.
  Setting `"language": "en"` fixed it and removed 182 ms (D6).

---

## T1 — Does the hotkey report key-up? (the one that matters)

`HotkeyMonitor` assumes `RegisterEventHotKey` delivers `kEventHotKeyReleased`.
Push-to-talk depends on it entirely, and nothing in this repository can prove
it without a keypress.

**Do:** hold **Control-Option-D** for about two seconds. Release it.

**Expect:** `[hotkey] key down` on press and `[hotkey] key up` on release.

**If `key up` never appears** — this is the most important negative result in
M0. The app will sit in `listening` forever and the menu bar icon stays filled.
Write down your macOS version and say so; the fallback is an `NSEvent` global
monitor, which changes the permission story and needs its own decision record.

## T2 — Permissions arrive at the right time (invariant 8)

**Do:** `tccutil reset Microphone com.cochlea.app`, relaunch, and watch the
launch **without touching the hotkey** for thirty seconds. Then press it.

**Expect:** no prompt at launch. The microphone prompt appears on the first
press, not before. Same for Accessibility.

**Note:** the first Accessibility grant usually needs the app relaunched, and
the first press after granting reports "grant it in System Settings, then press
again". That is expected, not a failure.

## T3 — Typing at the cursor, in the apps people use

`TextInjector` synthesises Unicode key events in 16-UTF-16-unit chunks. The
chunk size is described in the source as "conservative folklore, not a
documented limit".

**Do:** dictate one sentence into each of — TextEdit, Terminal, a browser text
field, and a chat box that sends on Enter.

**Expect:** the text appears at the cursor, complete, with nothing sent or
executed.

**Write down:** any dropped, duplicated or reordered characters, and which app.
Chunk boundaries are the suspect, so note whether damage lands near a multiple
of 16 characters.

## T4 — Long and non-Latin text

**Do:** dictate a long sentence (30+ words) in one breath. Then, if you can,
something in Chinese.

**Expect:** all of it arrives. `whisper-small` is weaker than turbo here, so
judge the *injection*, not the transcription — garbled recognition is a
different question from dropped characters.

**Watch for:** truncation at a consistent length. That is the chunking bug.

## T5 — The microphone actually closes

This one had a real bug (fixed): `endListening()` guarded on the wrong
condition, so after VAD ended an utterance mid-hold the microphone was never
closed.

**Do:** hold the hotkey, speak, then **keep holding in silence for two
seconds**, then release. Watch the orange microphone dot in the menu bar.

**Expect:** `[vad] silence ended the utterance while the key was still held`,
the text is typed, and on release the recording indicator **goes out**.

**Write down:** if the indicator stays on after release. That is a privacy bug
and it is the whole reason this test exists.

## T6 — Device change mid-session

`AVAudioConverter` is built once in `start()` from the input format at that
moment.

**Do:** dictate once with the built-in microphone. Connect AirPods (or any USB
interface), **and select them as the input device** in System Settings → Sound
→ Input — connecting them only changes *output*, and the bug needs the input
device to change. Dictate again without relaunching, then disconnect and
dictate a third time.

**Expect:** the second utterance transcribes.

**Write down:** silence, garbage, or a crash. The likely symptom is
`[capture] captured N samples` with a plausible N but empty or nonsense text,
because the converter is still resampling from the old device's rate.

## T7 — Latency, on your hardware

**Do:** dictate five ordinary sentences. Read the `[asr]` lines.

**Expect:** under 1000 ms warm — M0's acceptance criterion. The first press
after launch should already be warm, because the model is loaded at launch.

**Write down:** the five numbers and your Mac's model. D6 has one machine's
figures and explicitly says one machine is not enough to choose a default.

## T8 — Main-actor traffic

Every audio frame hops to the main actor. This compiles; whether it is too much
traffic is a runtime question, and Swift 6 strict concurrency will likely
object to it eventually.

**Do:** dictate a long utterance while dragging a window in another app.

**Expect:** no stutter in either.

**Write down:** dropped frames, UI hitching, or audio glitches. The fix is to
move the segmenter off the main actor.

---

## T9 — Streaming: does text arrive while you are still talking?

New, and the reason latch mode is usable for a paragraph. Never hand-tested.

Streaming is on by default. Confirm it in the menu bar → Settings… →
Dictation → **Type as I speak**, then:

1. Put the cursor in TextEdit.
2. **Tap** `⌃⌥D` (do not hold) so it latches.
3. Say a sentence, **pause for about a second**, say another, pause, say a
   third. Then tap `⌃⌥D` again to stop.

What should happen: each sentence appears at your cursor a moment after you
stop saying it, not all three at the end.

In the log you should see one `[vad] segment ended by a 0.7s pause` and one
`[inject] typed N characters` per sentence, alternating — never two `vad`
lines in a row before the first `inject`.

Three things to look at closely, because they are what streaming can get
wrong and F18 means none of them can be repaired after the fact:

- **Order.** Are the sentences in the order you said them? This is the failure
  that matters most. `CommitQueue` exists to prevent it, and the same work
  without it came out exactly reversed in a harness.
- **Spacing.** Is there exactly one space between sentences, and none before a
  comma or full stop? If you speak Chinese, check that no space appears
  between Chinese segments, and that a switch between languages reads
  correctly.
- **Cut points.** Does it ever cut mid-phrase? 0.7 s is a guess at a clause
  boundary. If it chops you off mid-sentence, say so and roughly how long your
  pauses are — the number is one line to change.

Then turn **Type as I speak** off and repeat. Nothing should appear until you
tap to stop. That difference is the whole setting.

---

## T10 — Activation modes and rebinding

Also new, also never hand-tested.

1. **Hold.** Hold `⌃⌥D`, speak, release. Should behave exactly as it always
   has.
2. **Tap.** Tap it. The menu bar icon should stay filled and the log should say
   `latched after a NNN ms tap`. Speak. Tap again to stop.
3. **The boundary.** A press of roughly 400 ms is ambiguous by construction.
   Try a few deliberate short presses and see whether the split feels right; if
   short deliberate utterances keep latching, `tapThresholdMillis` is too low.
4. **Rebind.** Settings… → Shortcuts, click the field, press something else
   (say `⌃⌥Space`). It should apply immediately, with no restart and no Apply
   button. Check the menu bar's first line now names the new shortcut, quit,
   relaunch, and confirm it survived.
5. **Reject a bad one.** Press a bare letter with no modifiers. It should
   refuse and say why, and the old shortcut should still work.
6. **Collide.** Bind it to something macOS already owns (`⌘Space`). It should
   fail with a readable reason and fall back to what was working — not leave
   you with no way to dictate.

---

## T11 — Teaching it your vocabulary, from the menu bar

The path the CLI already proves, done entirely by clicking. Never hand-tested.

Make a file to import first — a chat export, or just paste a few of your own
messages into a text file. Something with words you actually use that a
recogniser would get wrong.

1. Menu bar icon → **Settings… → Learning**. With nothing imported it should
   say so plainly rather than showing an empty table.
2. **Import from a file…** and choose your file.
3. **If it is a conversation**, cochlea should stop and ask *which speaker is
   you*, listing everyone it found with line counts. It must not import
   without an answer — learning the other person's vocabulary is the failure
   this question exists to prevent.
4. A sheet should list what it found: phrases separated from words, each with
   how often you wrote it. **Nothing has been saved at this point.** Cancel
   here and check the Learning tab is still empty.
5. Import again and press **Add**. The list should fill.

Then check it reached the recogniser:

```sh
dictate lexicon                      # what the app just wrote
```

Quit and relaunch the app, dictate a sentence containing one of the imported
words, and see whether it comes out right. The helper loads the lexicon at
startup, so a relaunch is required — if that turns out to be annoying in
practice, say so, because it is fixable.

Worth reporting either way:

- **Did it propose junk?** Ordinary words the recogniser already knows are
  supposed to be filtered out (F25), and every one that slips through is an
  entry that can only make things worse. Tell me what it offered that it
  should not have.
- **Did it miss something obvious** — a name, a tool, a piece of jargon you
  use constantly? That is the more interesting failure.
- **The minus button** next to an entry should remove it, and the change
  should survive a relaunch.

---

## T12 — Fixing what it got wrong

The point of the whole project, and the last thing standing between "a
dictation app" and "a dictation app that adapts". Never hand-tested.

Dictate a sentence containing a word you know it gets wrong — a name, a tool,
a piece of jargon. Then, **immediately**, press `⌃⌥F`.

1. A small panel should appear with what it heard, already selected for
   editing, and the keyboard focus in it.
2. Correct the wrong word. The panel should say how many characters it will
   delete.
3. Press **Fix it and remember** (or just Enter).

What should happen: the wrong text disappears from your document and the
corrected text replaces it, and the menu bar's last-event line says the
correction was saved.

Then check it landed:

```sh
dictate stats                  # utterances, and how many are trainable
dictate review                 # anything F1 could not classify
```

The interesting cases, and what each should do:

- **A genuine mishearing** ("nginx" heard as "gink's"), fixed within a few
  seconds → recorded as a *correction*, counted as trainable.
- **A change of mind** — dictate something, then use the panel to rewrite it
  into a completely different sentence → recorded as a *revision* and never
  trained on. The menu should say so. This is F1 doing its job; if a rewrite
  comes back as a correction, that is a real bug and the most valuable thing
  you could find here.
- **Something in between** — a fix that is neither obviously a mishearing nor
  obviously a rewrite → *quarantined*, and it should show up in
  `dictate review`.

Then the safety guards:

- **Wait three minutes** after dictating, then press `⌃⌥F`. The panel should
  open but refuse to touch the text, explaining that it cannot tell whether
  your cursor moved. "Remember it" should still work.
- **Dictate twice, then press `⌃⌥F`.** It should offer to fix the *second*
  utterance, not the first.
- **Press `⌃⌥F` with nothing dictated yet.** It should beep, not crash.
- **Move your cursor elsewhere, then fix.** It will delete the wrong
  characters — that is expected and is why the panel warns you. Try it in a
  scratch document, and tell me whether the warning is clear enough to stop
  you doing it by accident.

One thing to watch specifically: `⌃⌥D` and `⌃⌥F` are registered together now.
**Pressing `⌃⌥F` must not start dictation**, and pressing `⌃⌥D` must not open
the panel. If they cross over, the hotkey identity is not being read
correctly.

---

## What a useful report looks like

The log plus one sentence. For example:

> macOS 26.6.1, M2 8 GB. T1 passed — key up fires. T5 failed: indicator stayed
> on after release, log shows `[vad]` then nothing on release.

Paste the `[...]` lines. They carry the timing and ordering that a description
cannot.
