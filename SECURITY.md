# Security

## Reporting a vulnerability

Report privately through GitHub's
[private vulnerability reporting](https://github.com/lexian24/cochlea/security/advisories/new)
rather than opening an issue.

This is a personal project without a funded security team. Expect an
acknowledgement within a week and a fix timeline that depends on severity.
There is no bounty.

## What is in scope

cochlea runs entirely on one machine and has no server, so the interesting
surface is narrower than most projects. In rough order of severity:

**Model download.** `dictate` and the app fetch model weights from Hugging
Face on first run. Every file is checksum-verified against a digest pinned in
`ModelCatalog` before it is used. A way to make a download succeed with
content that does not match its pinned digest — or a way to get an unpinned
model installed — is the highest-severity bug in this project, because it ends
with attacker-controlled weights producing text at the user's cursor.

**The injector.** The app types at the cursor with
`CGEvent.keyboardSetUnicodeString`. Anything that makes it emit keystrokes the
user did not dictate, or emit them into an application they did not choose, is
in scope.

**The correction store.** `~/.cochlea/corrections.db` holds a record of what
someone has dictated, and `~/.cochlea/lexicon.json` holds terms lifted from
their own writing. Both are local, and the lexicon is written `0600`. A path
that widens those permissions, writes either outside `~/.cochlea`, or exposes
them to another process is in scope.

**Acoustic features**, when the user has opted in (they are off by default —
SPEC invariant 7). These are encrypted at rest. A way to read them without the
key, or to get them written when `text_only=True`, is in scope.

**The sidecar protocol.** The app talks to a Python child process over pipes.
Anything that lets a third party inject frames into that stream, or that makes
a malformed frame do more than close the connection, is in scope.

## What is not in scope

- **The app is unsigned, by decision.** Gatekeeper blocking a downloaded
  build is the intended behaviour, not a vulnerability — the app is meant to
  be compiled from source. See [F22](docs/SPEC.md).
- **A user granting Accessibility to a build they compiled themselves.** That
  is what building from source means.
- **Model output quality.** A mistranscription is a bug, not a vulnerability,
  unless it is attacker-controllable.
- **Anything requiring an attacker to already have code execution as the
  user.** At that point they can read `~/.cochlea` directly.

## What this project does not do

These are design constraints, not promises made in passing. If you find one
violated, that is a report worth making:

- **No network calls except model downloads.** No telemetry, no crash
  reporting, no analytics, no update check.
- **It does not read other applications' contents.** The Accessibility
  permission is used to *type*, never to read. There is no
  `AXObserver`, no text-field monitoring, and corrections are captured only
  through an explicit user action ([SPEC §1](docs/SPEC.md)).
- **It does not watch your keyboard.** The hotkey uses Carbon's
  `RegisterEventHotKey`, which delivers only the registered combination.
  There is no `CGEventTap`, which would see every keystroke on the system.
- **The microphone opens on the hotkey and closes when dictation ends**, with
  a hard cap on how long one session may run.

[`docs/PRIVACY.md`](docs/PRIVACY.md) says how to verify each of these
yourself.
