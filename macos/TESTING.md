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
interface). Dictate again without relaunching.

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

## What a useful report looks like

The log plus one sentence. For example:

> macOS 26.6.1, M2 8 GB. T1 passed — key up fires. T5 failed: indicator stayed
> on after release, log shows `[vad]` then nothing on release.

Paste the `[...]` lines. They carry the timing and ordering that a description
cannot.
