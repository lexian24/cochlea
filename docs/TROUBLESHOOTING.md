# Troubleshooting

Most of what looks broken here is deliberate, and the rest has a specific
cause. This page is ordered by how often each thing comes up.

If your problem is not here, the log usually is the answer — see
[SUPPORT.md](../SUPPORT.md).

## Nothing happens when I press the shortcut

**Check the log first.** Run the app from a terminal and press the shortcut:

```sh
./build/cochlea.app/Contents/MacOS/cochlea
```

- **No `[hotkey] key down` line at all** — something else on your Mac owns
  that combination. The app says so at launch if registration failed. Rebind
  it in Settings › Shortcuts.
- **`key down` but nothing after it** — the audio graph is stuck. This was a
  real bug with a stale input device; if you see it, the log lines around it
  are exactly what a report needs.
- **`permission` lines** — see [PERMISSIONS.md](PERMISSIONS.md).

## It asked for Accessibility and then still did not type

Expected on the very first grant. macOS usually wants the app restarted after
Accessibility is granted, so the first press after granting can do nothing.
Press again, or relaunch.

If it persists after a rebuild, permissions are keyed to a signature and an
ad-hoc build is keyed by path:

```sh
tccutil reset Accessibility com.cochlea.app
```

## The first word gets cut off

The microphone takes a moment to open. It should be ~100 ms after the first
press of a session; the log line is `key down to listening`. Anything
approaching a second will clip a word, and is worth reporting with the number.

If it is consistently slow, check that `[audio] graph prewarmed` appears at
launch — that is the work being paid up front so the first press does not.

## It typed nothing, and the log says the utterance was discarded

Two different messages, two different causes:

- **"nothing audible while the key was held"** — the microphone heard only
  room noise. Check you are on the input device you think you are.
- **"only N ms of speech, discarded as an accidental tap"** — you spoke for
  less than a quarter of a second. This guard exists so brushing the shortcut
  does not type a fragment.

Both lines print the measured noise floor and threshold. If the floor looks
absurd — much higher than your room — that is a bug worth reporting.

## Transcription is worse than I expected

- **Which microphone?** `whisper-small` is noticeably weaker on a narrowband
  Bluetooth headset than on the built-in mic. The same sentence went from
  "The deployment failed at midnight" to "The deployment fell at midnight"
  over AirPods. That is the audio, not the capture — the sample counts show it
  arrived intact.
- **Is the language pinned?** With `"language"` unset, Whisper detects it per
  30-second window, and a clipped window gets read as whatever it most
  resembles — then the *whole* window is mistranscribed. One English sentence
  came out as Malay this way. If you do not code-switch, pin it in Settings ›
  Dictation.
- **Teach it your words.** Settings › Learning › Import, or just fix a word
  once with the fix shortcut and it stops being misheard.

## I fixed a word and it got it wrong again

Check Settings › Learning. If the word is not in the list, the correction
deliberately taught nothing, and there are three reasons it might have:

- **Both words are ordinary.** `fell` → `failed` is two words the recogniser
  knows perfectly well, confused for acoustic reasons. Boosting one over the
  other cannot fix that and can make it worse.
- **They are homophones.** `there` → `their` cannot be separated by biasing at
  all, so an entry would create errors rather than remove them.
- **It was read as a rewrite.** If you changed the sentence substantially, the
  revision filter files it as a change of mind rather than a mishearing, and a
  change of mind is not evidence about the recogniser.

If none of those apply and the word still did not land, that is a bug.

**Also: the lexicon is read when the ASR helper starts.** Quit and relaunch
the app for a newly learned word to take effect.

## The fix shortcut says it is too late to fix the text

It is bounded at five minutes from when you *stopped* talking, and any new
dictation ends it. cochlea cannot see your document, so it cannot tell whether
your cursor has moved — the window is a bound on how wrong deleting characters
could be, not a check that it is right.

Recording the correction never expires. Only taking the text back does.

## Text appears in the wrong order, or with missing spaces

That is a bug, and a serious one — report it with the exact text. Streaming
commits each phrase separately and they are serialised precisely so this
cannot happen.

## The app will not open — "cochlea is damaged" or "cannot be opened"

You downloaded a build rather than compiling one. The app is not signed yet
(F22), so Gatekeeper refuses it. Build from source:

```sh
git clone https://github.com/lexian24/cochlea && cd cochlea
Tools/setup-testing.sh
```

A locally compiled app is not quarantined, so this works. Do not work around
it with `xattr -dr com.apple.quarantine` on a downloaded binary — that is a
habit worth not having.

## `dictate` is not found, or the app cannot find it

The app looks in `/opt/homebrew/bin` and `/usr/local/bin` and deliberately
does **not** consult `PATH`: an app launched from Finder does not inherit the
shell's `PATH`, so trusting it would work from a terminal and fail on
double-click.

`Tools/setup-testing.sh` links it where the app looks. Or set
`COCHLEA_DICTATE=/path/to/dictate`.

## `dictate asr-check` says asr is unavailable

Speech recognition is an optional extra, and Apple Silicon only — MLX has no
wheel for anything else:

```sh
pip install 'cochlea[asr]'
```

`dictate doctor` reports which backend is active.

## `pytest` fails on a clean checkout but passes for me

Use `pytest`, not `python -m pytest`. The latter prepends the working
directory to `sys.path`, which masks import errors that break a clean
checkout. That bug shipped once and CI was the only thing that caught it.

## brew install did not give me the app

It is not supposed to. The formula installs the `dictate` CLI only; the menu
bar app needs signing before a cask is honest. See
[RELEASING.md](RELEASING.md).

## Starting over

```sh
dictate purge                 # the correction store
rm ~/.cochlea/lexicon.json    # the words it learned
rm -rf ~/.cochlea             # everything, including the model
```
