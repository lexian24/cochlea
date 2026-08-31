# Stage 2 — cochlea on iPhone

**Status: designed, not built. Do not start this until stage 1 (a Mac app that
actually works) is done.** F24 is the spec's own warning about scope, and this
is exactly the kind of expansion that stalls a project. It is written down now
because thinking it through cost an afternoon and revealed that it constrains
stage 1 almost not at all — which is worth knowing before someone assumes it
does.

## What this is

cochlea is a Mac tool. The iPhone gets an **extension** of it, not a copy.

- The Mac captures corrections, trains, and owns the lexicon.
- The iPhone receives a read-only snapshot of that lexicon and uses it to fix
  Apple's dictation output.
- **Nothing on the iPhone flows back.** The phone is a pure replica. It never
  writes to the correction store, never trains, never contributes a correction.

You keep using Apple's built-in keyboard dictation. cochlea never touches the
microphone on iOS.

## The decision that makes this tractable

One-way was not the obvious choice — a phone that contributes corrections
sounds strictly better. It is not. Making the Mac the only writer eliminates
three separate problems outright:

1. **No conflict resolution.** Two writers means the same utterance can be
   corrected differently on each device, and the schema has no way to even
   detect that. One writer means no merge strategy, no `device_id`, no clocks.
2. **No shared holdout.** Invariant 2 says holdout data is never trained on. If
   the phone trained, that invariant would have to span devices or the gate
   would silently stop meaning anything. The phone does not train, so it
   cannot.
3. **No mixed error distributions.** A post-correction adapter learns *"this
   engine mishears X as Y."* Apple's dictation and Whisper have different error
   modes. Pooling corrections from both into one adapter fits one model to two
   distributions — mediocre at each, and a mixed holdout would not catch it.
   §1.3 says text pairs are base-model-agnostic, which is true about
   *portability* and misleading about *error distribution*. One-way sidesteps
   this entirely.

**Consequence: no schema change is required.** An earlier draft of this design
recommended adding `device_id` and a global holdout flag as cheap insurance.
Under one-way sync neither is needed. The correction store is untouched.

## What ports, and what does not

| Layer | On Mac | On iPhone |
|---|---|---|
| **1 — Lexicon** | Decode-time biasing inside Whisper's decode loop | **Post-hoc replacement** over Apple's output |
| **2 — Post-correction LM** | LoRA on a 0.6B model | **Does not run.** See below |
| **3 — Acoustic LoRA** | Bound to Whisper's weights | Never. Different base model, and no mic anyway |

### Layer 2 does not fit

A keyboard extension is killed by jetsam somewhere around **60 MB** of
`phys_footprint` — silently, with no crash log and no signal. A 4-bit 0.6B
model is roughly 400 MB. This is not a tuning problem, it is an order of
magnitude. The container app cannot be woken reliably in the background to do
it either.

Dropping layer 2 is not much of a loss here. Apple's dictation fails on proper
nouns, project jargon and code-switched words — single-token substitutions,
which are exactly lexicon-shaped. Layer 2 handles homophones and sentence-level
grammar, which is lower value per unit of effort. The phone keeps the half that
fixes the actual complaints.

### Layer 1 changes mechanism, and gets more dangerous

This is the part to be careful about.

On the Mac, layer 1 nudges token scores inside the decode loop, and
[F2](SPEC.md#f2--biasing-over-triggers-and-creates-new-errors)'s safety rail is
*"apply boost only when the base model's acoustic score for the alternative is
within a margin."* That margin is what stops "young" becoming "Giang"
everywhere.

Apple's dictation is a black box. You get final text — no lattice, no scores.
So on iPhone layer 1 degrades to **fuzzy replacement with no acoustic evidence
at all**, guessing from spelling alone. That is F2 with its safety rail
removed: the iPhone version is strictly more dangerous than the Mac version,
not less.

The only remaining evidence is phonetic distance between Apple's output and the
lexicon entry — which is `src/cochlea/phonetics.py`, already built and tested.
It has to carry more weight here than it does on the Mac, so the threshold
should be tuned conservatively and the UI must fail safe.

## The interaction

1. User taps the mic on **Apple's** keyboard and dictates. Text lands in the
   field. Nothing to do with cochlea.
2. User taps the globe key once. The cochlea keyboard appears.
3. It reads the surrounding text through `UITextDocumentProxy`
   (`documentContextBeforeInput`) and shows a **suggestion strip** above the
   keys: `Giang?` `kubectl?`
4. Tap to apply. Or ignore it and carry on.

**Never auto-replace.** A suggestion that goes untapped costs nothing; a bad
auto-replacement in a work email is
[F12](SPEC.md#f12--profile-bleed-is-asymmetric)'s embarrassing direction with
no fix-last to undo it. Suggestion-not-replacement is also the native iOS
idiom, so it needs no explaining.

Note the loop does **not** close: a tap applies a fix locally and is then
forgotten. That is the cost of one-way, and it is deliberate — the alternative
reintroduces all three problems above.

## Sync

### Payload

Only the **derived lexicon**, never the correction store. This matters: the
store is a rolling record of everything ever dictated
([F7](SPEC.md#f7--the-audiomel-store-is-a-rolling-record-of-everything-dictated)),
and under this design it never leaves the Mac. The phone receives a word list.

Sketch — versioned, and a **full snapshot, not a delta**:

```
lexicon_export:
  schema_version
  generated_at
  source_device            -- provenance only, not an identity claim
  entries[]:
    term                   -- "kubectl"
    language               -- "en"
    boost                  -- post-cap, post-decay value from the Mac
    phonetic_key           -- precomputed, but see below
    slang                  -- bool, drives the conservative default
```

### Snapshot, not merge — and this is load-bearing

The phone must **replace its lexicon wholesale** on every sync.

[F2](SPEC.md#f2--biasing-over-triggers-and-creates-new-errors)'s decay and
expiry are safety mechanisms: they are how the Mac learns that an entry
over-triggers and drops it. If the phone merges rather than replaces, those
removals never propagate, and the phone accumulates precisely the entries the
Mac learned were harmful — while having no acoustic margin to protect itself.
A merging phone gets monotonically worse.

### Phonetic keys

The phone needs the phonetic algorithm at runtime, not just precomputed keys:
it must compute a key for whatever arbitrary word Apple produced in order to
compare it against the lexicon. So metaphone has to be ported to Swift.

Port it with a **golden-file test**: generate `(word, key)` pairs from the
tested Python implementation, ship them as a fixture, and have the Swift test
assert parity. That is what stops the two implementations drifting, which would
show up as suggestions that fire on the Mac and not the phone, or worse.

`pinyin` needs a hanzi table and is a bigger port. Defer it; zh falls back to
character-level edit distance, which the
[P5](SPEC.md#p5--multilingual-user-whose-language-pair-we-have-not-built-for)
contract already allows.

### Transport

Local network only (Bonjour, both devices on the same Wi-Fi). The README's
claim is *"Nothing leaves your machine. There is no server to send it to,"* and
that should stay true.

A word list is far less sensitive than a transcript archive, so iCloud is
*arguable* here in a way it never was for the store — but it still contains
your colleagues' names and your employer's project code names, and the claim is
worth more than the convenience.

## Permissions — a correction to an earlier assumption

**"Allow Full Access" is mandatory.** An earlier version of this design assumed
the keyboard could work without it using a bundled lexicon. That is wrong: the
app bundle is immutable after install, so a lexicon that grows can only reach
the extension through an App Group shared container, and App Group access from
a keyboard extension requires Full Access. There is no useful degraded mode.

This is [F9](SPEC.md#f9--reading-chatdb-looks-alarming) on a bigger stage — iOS
describes this permission to users in the most alarming language it has.

The mitigation is that under one-way sync the honest explanation is unusually
strong, and verifiable: **the keyboard never uses the network.** Full Access is
required by iOS solely to read your vocabulary file from the app. Nothing is
sent anywhere, because there is nowhere to send it and no code that could. Say
this at the moment the permission is needed, never at install.

## Failure modes

Registered in the spec's idiom. Numbering continues from F24.

#### F25 — A stale phone lexicon keeps entries the Mac has dropped

F2's decay and expiry exist to remove entries that over-trigger. A phone that
merges instead of replacing never sees the removals and accumulates exactly the
harmful entries — with no acoustic margin to protect it. **Mitigation:** full
snapshot replace; a generation counter on the export; a visible "last synced";
and an age beyond which the phone stops suggesting rather than suggesting from
a stale list.

#### F26 — Post-hoc replacement has no acoustic evidence

F2 without its safety rail. **Mitigation:** suggest, never replace; a
conservative phonetic threshold, tuned separately from the Mac's; and a floor on
term length, since short words are where spelling-only matching goes wrong.

#### F27 — Full Access reads as alarming in a privacy-positioned tool

**Mitigation:** no network entitlement exercised by the extension at all, so the
explanation is verifiable rather than a promise; requested at first use, never
at install; documented in the App Store description.

#### F28 — Profile selection does not port

[F11](SPEC.md#f11--one-adapter-cannot-serve-all-contexts) keys profiles on the
frontmost application. A keyboard extension has no public API for the host
app's identity, so app-keyed selection is simply unavailable, and with it
F12's automatic suppression of slang in formal contexts. **Mitigation:** the
phone defaults to the **conservative/formal** profile. F12's asymmetry says the
costs are unequal — work jargon in a personal message is harmless, personal
slang in a work email is not — so when the context cannot be known, the safe
direction is the formal one. A manual switcher in the container app is the
escape hatch.

#### F29 — The keyboard is killed silently at the memory ceiling

Jetsam gives no crash log and no signal, so this presents as "the keyboard
just disappears." **Mitigation:** a hard budget with no model of any kind; a cap
on lexicon entries with the export truncated by boost rank; and a memory
assertion in the extension's own tests.

## Invariants for this target

1. The correction store never leaves the Mac.
2. The phone never writes to the correction store, and never trains.
3. The phone replaces its lexicon wholesale; it never merges.
4. The keyboard never touches the microphone, and never uses the network.
5. Suggestions are applied by the user, never automatically.

## What stage 1 has to do for this

Almost nothing, which is the point of writing it down now.

- **No schema change.** See above.
- **No architectural change.** The correction store, adapters and training path
  are untouched.
- **One dependency, already on the M2 path:** the lexicon must be *persisted*
  before there is anything to export — today `dictate lexicon` is a stub and
  extraction is in-memory. That work is M2's, not stage 2's.
- A `dictate export --lexicon` command is additive and can be written whenever;
  the export is derived data, so getting the format wrong costs a regeneration,
  not a migration.

## Verify before building

- **`documentContextBeforeInput` truncation.** It is not documented as
  returning the whole field and behaviour varies by host app. If it returns
  only a short window, "fix the last utterance" may not see the whole
  utterance. This decides whether the interaction works at all.
- **Secure text fields** return nil — confirm that degrades quietly rather than
  showing an empty suggestion strip.
- **Whether one globe tap is tolerable** in daily use, or whether switching back
  to Apple's keyboard for the next dictation kills it. Test this with a paper
  prototype before writing an extension.
- The 60 MB ceiling, on a real device, with a realistic lexicon loaded.

## Rejected alternatives

- **Bidirectional sync.** Reintroduces conflict resolution, cross-device
  holdout and mixed error distributions, for a correction signal the Mac
  already collects better.
- **Running Whisper on the phone.** 1.6 GB, thermals, battery — and it would
  make the phone a second base model, which is the whole problem in §1.3.
- **A keyboard that does its own dictation.** iOS keyboard extensions cannot
  access the microphone. Hard restriction since iOS 8, unchanged.
- **App-switch-to-record**, as Wispr Flow and Spokenly do. It works and it is
  how everyone else gets around the mic restriction, but it abandons Apple's
  dictation — the thing the user actually likes — for a worse recording flow.
