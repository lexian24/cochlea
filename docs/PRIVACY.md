# Privacy, and how to check it

Every claim below can be verified from outside the project. Where a claim
rests on a design decision, the reason is linked; where it rests on code,
the file is named.

This page describes what the software does. It is not a legal document,
because there is no service and no other party — nobody to make promises to
you and nobody to break them.

## The short version

cochlea runs on one machine. It makes exactly one kind of network request —
downloading a speech model, once, from Hugging Face — and never sends
anything anywhere. There is no account, no telemetry, no crash reporting, no
update check, and no server that could exist to receive your speech.

## What is stored, and where

Everything lives in `~/.cochlea`. You can read all of it, and deleting the
directory removes every trace.

| File | Holds | Notes |
|---|---|---|
| `config.json` | Your settings | Plain JSON. |
| `models/` | Speech model weights | Downloaded once, checksum-verified. |
| `lexicon.json` | Words and phrases to bias towards | Written `0600`. Terms taken from your own writing. |
| `corrections.db` | Utterances and the corrections you made | SQLite, readable with any client. |
| `adapters.db` | Trained adapter versions and eval scores | Empty until training exists. |
| `features/` | Acoustic features | **Nothing writes this today.** The store exists and is tested; nothing in the app or CLI is wired to it, because acoustic retention lands at M5 and is opt-in. When it does, features are encrypted at rest. |

Check it yourself:

```sh
ls -la ~/.cochlea
sqlite3 ~/.cochlea/corrections.db 'select hypothesis, final_text from utterance'
cat ~/.cochlea/lexicon.json
```

The correction store being plain SQLite is deliberate
([SPEC §1.3](SPEC.md)): a store you cannot inspect is a privacy claim you have
to take on faith.

## What it does not do

**It does not read other applications.** The Accessibility permission is used
to *type* at your cursor, never to read what is there. There is no
`AXObserver`, no text-field monitoring, and no polling of the focused
element. This is the single most important constraint in the design and it is
the reason corrections have to be made through an explicit action rather than
detected automatically ([SPEC §1](SPEC.md#1-decisions-to-lock-before-writing-code)).

The cost is real and was accepted knowingly: cochlea will capture far fewer
corrections than a design that watched your editor, so it learns more slowly.
That trade is the whole point.

**It does not watch your keyboard.** The dictation shortcut is registered with
Carbon's `RegisterEventHotKey`, which delivers only the combination that was
registered. The alternative — a `CGEventTap` — would see every keystroke on the
system, and no amount of promising not to look at them would make that
acceptable. See `macos/Sources/CochleaInput/HotkeyMonitor.swift`.

**It does not keep the microphone open.** Capture starts on the hotkey and
stops when dictation ends, with a hard cap on one session
(`maximumUtteranceSeconds`, five minutes by default) so a session you walked
away from cannot run indefinitely. The menu bar icon inverts for exactly as
long as the microphone is open — that state change is deliberately the largest
one in the icon set.

**It does not keep your audio.** Samples are held in memory for the length of
one utterance and discarded after transcription. Nothing writes a `.wav`, and
nothing today writes acoustic features either — the encrypted store for them
is built and tested but nothing is wired to it, because that layer is M5 and
opt-in. When it arrives, `CorrectionStore(text_only=True)` *refuses* features
at the boundary rather than omitting them, so the default cannot be weakened
by an oversight somewhere else ([invariant 7](SPEC.md#6-invariants)).

**It does not ask for permission before you need it.** Both prompts appear on
your first dictation, never at launch. An app that asks for your microphone
before you have used it is asking you to trust it with no evidence
([invariant 8](SPEC.md#6-invariants)).

## The one network request

On first run, the model weights are downloaded from Hugging Face. Every file
is verified against a SHA-256 pinned in `ModelCatalog` before it is used, so a
compromised mirror produces a checksum failure rather than
attacker-controlled weights ([D4](DECISIONS.md)). Adding a model to the
catalogue requires running `scripts/pin-model.sh` for it; an unpinned model
cannot install.

You can watch for anything else:

```sh
# Should show traffic to huggingface.co on first run, and nothing after.
sudo lsof -i -a -c cochlea -c dictate
```

Or block it entirely — download the model yourself, put it in
`~/.cochlea/models/`, and the app never reaches the network again.

## Importing your own writing

`dictate import` reads text you point it at, to seed the vocabulary. Three
things about it:

**It asks who you are, and refuses to guess.** A chat export is a
conversation, and half of it belongs to someone else. When the importer finds
more than one speaker and you have not said which is you, it stops rather
than importing both sides — learning the other person's vocabulary is a
privacy failure as much as a quality one
([invariant 3](SPEC.md#6-invariants), [D10](DECISIONS.md)).

**It redacts before it stores.** Email addresses, URLs, numbers and postcodes
are replaced with placeholders inside the importer, before anything is
yielded — not filtered afterwards, because store-then-filter has already
stored it ([F8](SPEC.md)).

**It shows you everything before keeping any of it.** `dictate import` writes
nothing without `--commit`, and the app's import shows the proposal in a sheet
you can cancel. This is text lifted out of your private messages; the least a
tool can do is show you what it took.

## Someone else uses your Mac

This is a known gap, honestly stated. Speaker verification is designed but not
built ([F10](SPEC.md), M5). Until it exists, dictation by a second person
would be learned from as though it were you.

The stopgap is in the menu bar: **Pause learning**. It is deliberately not
buried in Settings, because the person who needs it is often not the person
who installed the app.

## If you change your mind

```sh
dictate purge --audio     # acoustic feature rows only
dictate purge             # everything in the correction store
rm ~/.cochlea/lexicon.json    # the words it learned
rm -rf ~/.cochlea             # everything, including the model
```

Uninstalling never removes `~/.cochlea`. The Homebrew cask puts it under `zap`
rather than `uninstall` so that `brew uninstall` cannot silently destroy a
record of what you have dictated.

## Reporting a problem

If something here is not true, that is a security report:
[SECURITY.md](../SECURITY.md).
