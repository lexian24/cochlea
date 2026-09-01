# Permissions

cochlea asks for two, and asks for each one the first time you use the feature
that needs it — never at launch. That is
[invariant 8](SPEC.md#6-invariants), and it exists because an app that asks
for your microphone before you have used it is asking you to trust it with no
evidence.

## Microphone

**Asked for:** the first time you press the dictation shortcut.

**Used for:** hearing what you dictate. Capture starts on the shortcut and
stops when dictation ends, with a hard cap on one session
(`maximumUtteranceSeconds`, five minutes by default) so a session you walked
away from cannot run indefinitely.

**How to see it is closed:** the menu bar icon inverts — the mark knocked out
of a filled block — for exactly as long as the microphone is open, and returns
to the plain mark when it closes. That change is deliberately the largest one
in the icon set, because this is the question the app cannot afford to answer
subtly.

Audio is held in memory for one utterance and discarded after transcription.
Nothing writes a `.wav`.

## Accessibility

**Asked for:** the first time you press the dictation shortcut, immediately
after the microphone prompt.

**Used for:** typing the transcript at your cursor, and — only when you ask
for it with the fix shortcut — taking that text back to replace it.

**Not used for reading.** There is no `AXObserver`, no text-field monitoring,
and no polling of the focused element. cochlea cannot see what is in your
document; the only thing it knows about it is what it put there itself. This
is why corrections have to be made through an explicit action rather than
detected automatically, and it is the most consequential constraint in the
whole design ([SPEC §1](SPEC.md#1-decisions-to-lock-before-writing-code)).

macOS usually wants the app restarted after this grant, so a refusal on the
very first press is expected rather than a failure — the app says so instead
of looking broken.

## What it does not ask for

- **Input Monitoring.** The dictation shortcut is registered with Carbon's
  `RegisterEventHotKey`, which delivers only the combination that was
  registered. A `CGEventTap` would see every keystroke on the system and would
  need this permission; cochlea does not use one.
- **Full Disk Access.** Nothing reads `~/Library`. If a Messages importer is
  ever added it would need this, and it would ask at that point, for that
  feature only.
- **Screen Recording**, **Camera**, **Contacts**, **Calendar**, **Photos**,
  **Location**, or **Network**. None are used.

## Granting, checking and revoking

System Settings › Privacy & Security, then Microphone or Accessibility.
Revoking either stops the corresponding half of dictation and nothing else;
the app keeps running and says what is missing.

## When permissions get confused

This happens with a **locally built** app, and the reason is worth knowing:
macOS keys permission grants to a code signature, and a build signed ad-hoc is
keyed by path instead. Rebuilding can therefore lose or duplicate a grant.

```sh
tccutil reset Accessibility com.cochlea.app
tccutil reset Microphone com.cochlea.app
```

Then grant again on the next press. A properly signed release does not have
this problem — grants survive updates — which is one of the reasons signing
matters beyond getting past Gatekeeper ([RELEASING.md](RELEASING.md)).
