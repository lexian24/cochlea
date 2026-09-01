# Personalized dictation — engineering spec and handoff

An open-source macOS dictation app whose model adapts to one person.
Distributed via Homebrew. Audience is technically comfortable users.
Local-only; no cloud.

This document is the handoff brief. It records the design decisions, the
failure modes we expect, the personas the design must serve, and a milestone
plan with acceptance criteria.

**Status: M0 transcribes; the capture path is unproven.** This document is
the brief as handed over. What has been built since, and what contradicted
it, is recorded in [Appendix B](#implementation-state) and
[docs/DECISIONS.md](DECISIONS.md) rather than by editing the brief.

## Contents

- [1. Decisions to lock before writing code](#1-decisions-to-lock-before-writing-code)
  - [1.1 The correction-capture boundary](#11-the-correction-capture-boundary)
  - [1.2 Audio retention format](#12-audio-retention-format)
  - [1.3 The durable asset is the correction store, not the adapter](#13-the-durable-asset-is-the-correction-store-not-the-adapter)
- [2. Failure mode register](#2-failure-mode-register)
  - [2.1 Correction loop pathologies](#21-correction-loop-pathologies) (F1–F6)
  - [2.2 Privacy and data](#22-privacy-and-data) (F7–F9)
  - [2.3 Multi-user and multi-context](#23-multi-user-and-multi-context) (F10–F12)
  - [2.4 Model lifecycle](#24-model-lifecycle) (F13–F17)
  - [2.5 Performance and UX](#25-performance-and-ux) (F18–F20)
  - [2.6 Project-level](#26-project-level) (F21–F26)
- [3. Personas and journeys](#3-personas-and-journeys) (P1–P6)
- [4. Architecture](#4-architecture)
- [5. Milestones](#5-milestones) (M0–M6)
- [6. Invariants](#6-invariants)
- [7. Open questions](#7-open-questions)
- [Appendix A: failure mode → milestone traceability](#appendix-a-failure-mode--milestone-traceability)
- [Appendix B: editorial notes on this document](#appendix-b-editorial-notes-on-this-document)

---

## 1. Decisions to lock before writing code

These three shape the schema. Changing them later means a migration.

### 1.1 The correction-capture boundary

We type text at the user's cursor in a foreign application. Any edit they make
there happens outside our process. We do not monitor arbitrary text fields via
the Accessibility API — it is fragile, breaks on every app update, and
contradicts the privacy positioning.

Corrections are therefore captured only through explicit user actions:

- **Fix-last hotkey** — reopens the most recent utterance in a small panel with
  the audio available for replay. Primary path, used within seconds of the
  error.
- **Review queue** — a batch UI listing recent transcripts. The user clears it
  when idle. Secondary path, catches what fix-last missed.

**Consequence:** correction volume will be lower than a naive design assumes.
Every downstream estimate of "how long until we can train" must use realistic
capture rates, not error rates. Instrument this from M1 so we learn the real
number early.

### 1.2 Audio retention format

**Decision:** store log-mel spectrograms by default; raw audio only with
explicit per-session opt-in.

**Rationale:** Whisper's encoder consumes log-mel, so mel features are
sufficient for acoustic fine-tuning while being substantially harder to
casually listen to. Raw audio in a folder on disk is the single largest
reputational risk in this project.

**Cost:** mel bin counts are model-specific (80 for most Whisper variants, 128
for large-v3). Mel-only storage locks a correction to the base model that
produced it. Accept this. Users who want base-model portability opt into raw
audio and are told exactly what that means.

### 1.3 The durable asset is the correction store, not the adapter

Base models will be replaced. Every LoRA adapter is bound to specific base
weights and becomes worthless on upgrade. So:

- Adapters are derived artifacts. Delete-and-rebuild must always be possible.
- The correction store is the source of truth and must be schema-versioned,
  human-inspectable, and exportable.
- `dictate rebuild` regenerates all adapters from the store against the current
  base model. This command exists from M4 onward and is tested every milestone.

Text-pair corrections (which drive the lexicon and post-correction layers) are
fully base-model-agnostic and survive any upgrade. Only acoustic adaptation is
affected — communicate that asymmetry to users.

---

## 2. Failure mode register

Each entry: what breaks, why, mitigation, and the milestone that must handle
it.

### 2.1 Correction loop pathologies

#### F1 — Revision mistaken for correction

User edits text because they changed their mind, not because ASR erred.
Training on this teaches noise.

**Mitigation:** three-signal filter — edit latency (corrections happen fast),
phonetic distance between original and replacement (corrections are
phonetically close), and edit locality (corrections are short substitutions,
revisions are rewrites). Quarantine anything that fails two of three; surface
quarantined items in the review queue for manual adjudication. **M1.**

#### F2 — Biasing over-triggers and creates new errors

Once "Giang" is boosted, the genuine word "young" starts transcribing as
"Giang." The lexicon becomes a source of errors rather than a fix.

**Mitigation:** cap boost magnitude; apply boost only when the base model's
acoustic score for the alternative is within a margin; track negative signal —
if the user deletes a boosted token, decay that entry's weight; expire entries
unused for N weeks. Log boost-attributed changes so `dictate eval` can measure
whether biasing is net positive. **M2.**

#### F3 — Catastrophic forgetting

Training only on corrected utterances teaches the model that its correct
outputs were wrong.

**Mitigation:** replay buffer — every training batch mixes corrected utterances
with accepted-as-correct utterances at a fixed ratio, plus a small generic set.
Never train on a corrections-only dataset. **M4.**

#### F4 — Survivorship bias in the signal

We observe errors, not successes. "No edit" is weak evidence of correctness —
the user may not have noticed or may have fixed it elsewhere.

**Mitigation:** treat un-edited utterances as weak positives with lower sample
weight. Do not treat them as gold labels. **M4, recurring at M5.**

*Assigned during handoff; the brief left this one unnumbered. F4 and
[F3](#f3--catastrophic-forgetting) are the same code path: F3's replay buffer
mixes corrected utterances with "accepted-as-correct" ones, and the
accepted-as-correct pool **is** the un-edited set. The sample weight F4 asks for
is set exactly where that buffer is composed, so it lands with the first trainer
(M4) and must be re-applied when the acoustic trainer arrives (M5). Building the
replay buffer without it is the bug F4 describes.*

#### F5 — Homophones cannot be fixed by lexicon

No amount of vocabulary helps distinguish two words that sound identical.
Boosting actively hurts here.

**Mitigation:** accept the limit. Route disambiguation to the post-correction
LM, which has sentence context. Document that lexicon entries for common-word
homophones will be rejected. **M2.**

#### F6 — Inconsistent orthography in the user's own data

They write "la" and "lah" interchangeably. The model learns a coin flip.

**Mitigation:** variant detection at import time. When two spellings of the same
token exceed a frequency threshold, ask the user to pick a canonical form. This
is a good UX moment, not an annoyance — it demonstrates the product thesis.
**M2.**

### 2.2 Privacy and data

#### F7 — The audio/mel store is a rolling record of everything dictated

This plausibly includes credentials, health information, and private messages.

**Mitigation:** encryption at rest with a Keychain-held key (do not rely on
FileVault being on); hard retention cap in both hours of audio and days of age,
whichever binds first; visible storage indicator in the UI; one-click purge;
exclusion from Time Machine and iCloud via the appropriate `NSURLIsExcluded`
attributes and a `.nobackup` marker. Acoustic retention defaults off. **M5.**

#### F8 — Imported chat data contains other people's messages

Group chats, quoted replies, forwarded content.

**Mitigation:** every importer filters to the user's own messages at parse time
and discards others before anything is written to disk. Do not store-then-filter.
Strip obvious PII patterns (long digit sequences, email addresses, postal
addresses) from retained text. **M2.**

#### F9 — Reading `chat.db` looks alarming

Requesting Full Disk Access in a privacy-positioned tool needs careful framing
or it reads as contradiction.

**Mitigation:** the importer explains exactly what it reads and what it retains
before requesting permission, shows a preview of extracted terms, and requires
confirmation. Never request the permission at launch. **M2.**

### 2.3 Multi-user and multi-context

#### F10 — Someone else speaks into the mic

A colleague borrows the laptop, or a meeting is picked up. Their audio pollutes
the training set and degrades the personal model.

**Mitigation:** speaker verification. Compute an embedding (ECAPA or CAM++
class, small and fast) at enrollment; compare every training-candidate
utterance against it; quarantine mismatches rather than discarding, and surface
them in the review queue. This is cheap and also catches accidental capture.
**M5.**

#### F11 — One adapter cannot serve all contexts

Coding jargon in a text to a friend is wrong; slang in a work email is worse.

**Mitigation:** decompose by what actually varies. Acoustic adaptation is
per-person (the voice does not change with context). Lexicon and style are
per-profile, keyed on the frontmost application. One acoustic adapter, several
lexicon/style profiles. **M6.**

#### F12 — Profile bleed is asymmetric

Work jargon appearing in personal dictation is harmless; personal slang in a
work email is embarrassing.

**Mitigation:** profiles carry a formality flag. In formal contexts, apply
lexicon boosting conservatively and disable slang-derived entries. **M6.**

### 2.4 Model lifecycle

#### F13 — Base model upgrade orphans every adapter

Covered in [§1.3](#13-the-durable-asset-is-the-correction-store-not-the-adapter).

**Mitigation:** `dictate rebuild`. Store is source of truth. **M4.**

#### F14 — A bad training run silently degrades the daily driver

The user notices the app got worse and cannot say why. This kills trust faster
than any other failure.

**Mitigation:** no adapter is ever promoted without passing the eval gate.
Automatic rollback on regression. Keep the last N adapters (they are tens of
MB). `dictate rollback` is a user-facing command. **M3, enforced from M4
onward.**

#### F15 — Unreproducible regressions

"It was better last week."

**Mitigation:** log adapter version, base model version, config hash, and eval
score with every session. `dictate doctor` dumps this for bug reports. **M3.**

#### F16 — Eval set overfitting

If we train until the enrollment recording passes, we overfit to read speech
and to a fixed set.

**Mitigation:** the enrollment recording is a smoke test, not the gate. The real
gate uses a rolling holdout — a fixed fraction of corrections is permanently
reserved, never trained on, and rotated on a schedule. **M3.**

#### F17 — WER is the wrong metric

Users do not experience WER. They experience how often they have to fix
something, and a wrong proper noun costs far more than a wrong article.

**Mitigation:** the primary metric is corrections per 100 words dictated,
measured from real usage — free to collect and directly meaningful. Secondary:
entity error rate on the holdout. WER is reported but is not the gate. **M3.**

### 2.5 Performance and UX

#### F18 — Layer stacking adds latency

Base ASR plus a post-correction LM pass is two model invocations. Dictation
must feel immediate.

**Mitigation:** budget end-to-end latency explicitly (target: under 1s for a
typical utterance on M-series). The post-correction pass runs only in
commit-on-release mode. In live streaming mode, post-correction is disabled —
it cannot revise already-typed text without backspacing, which breaks terminals
and send-on-enter chat boxes. Make this an explicit, documented mode
difference. **M4.**

#### F19 — Model load time on first invocation

A multi-second delay on the first hotkey press feels broken.

**Mitigation:** keep the model resident; warm it at launch. Accept the RAM cost
and document it. Offer a smaller model for constrained machines. **M0.**

*Assigned during handoff; the brief left this one unnumbered. Residency is a
process-model decision, not a later optimization — a design that loads on demand
cannot have warm-up bolted on without restructuring. It also sits directly
under M0's latency bar and under [F24](#f24--scope): the first hotkey press is
the first thing a new user experiences, and "feels broken" at that moment costs
the retention every downstream milestone depends on.*

#### F20 — Training competes with the user's work

Thermal throttling, memory pressure, battery drain.

**Mitigation:** training is gated on AC power, idle detection, and
not-in-low-power-mode. A resource guard aborts the run if memory pressure would
force swap. Training is always resumable and never blocks dictation. **M4.**

### 2.6 Project-level

#### F21 — Homebrew formula cannot ship a 1.6GB model

**Mitigation:** formula installs the binary only; models download on first run
with checksum verification and a resumable transfer. **M0.**

#### F22 — Gatekeeper blocks an unsigned app requesting Accessibility and Full Disk Access

This is a hard blocker for non-CLI distribution and costs money (Apple Developer
Program membership) plus notarization setup.

**Mitigation:** resolve before M0 ships. If unsigned initially, document the
override path honestly and prominently. Do not pretend it is not friction.
**Before M0 ships.**

#### F23 — Licensing on models and data

Whisper is MIT. Parakeet, SenseVoice, MERaLiON weights, and the National Speech
Corpus each carry their own terms — NSC in particular has usage and attribution
conditions that apply if we distribute an adapter trained on it.

**Mitigation:** audit every weight and dataset before distribution. Record the
license of each shipped artifact in a `LICENSES-MODELS.md`. **Before any
community adapter ships.**

#### F24 — Scope

This project is large enough to stall.

**Mitigation:** M0 must be a genuinely good dictation app with no learning at
all. If M0 is not competitive with existing tools, nothing downstream matters,
because nobody stays long enough to generate corrections. **M0.**

#### F25 — The lexicon fills with words the model already knows

Term extraction decides what counts as project vocabulary by asking whether a
word is absent from a baseline list. Every ordinary word the list happens to
miss therefore becomes a lexicon entry — and an entry for a word Whisper
already gets right cannot help, only push that word over something the user
actually said. This is F2 arriving through the import path rather than through
the correction loop, and it arrives in bulk: six lines of chat proposed
`gate`, `logs` and `request` alongside `kubectl` and `nginx`.

The baseline is the weak point and it is structural. A word list that is small
enough to read is too small to be a frequency model, and a spelling dictionary
large enough to cover ordinary English also covers the rare words a user
genuinely needs boosted.

**Mitigation, in force:** the baseline was widened and made suffix-aware, so
inflections match their lemma (`logs` → `log`); phrases made entirely of
ordinary words are refused outright; and `dictate import` proposes without
writing, so a human sees every entry before it can bias anything. **M2.**

**Mitigation, still owed:** the right signal is not an English frequency list
at all but the ASR model's own tokenizer — a word it encodes as one token is
one it knows, and a word that shatters into pieces is one it will get wrong.
That is available wherever the ASR extra is installed and is the correct
long-term replacement for the bundled list.

#### F26 — Asynchronous commits reach the cursor out of order

Anything that transcribes more than one piece of audio per dictation session
must type them in the order they were spoken. Independent tasks do not: a
shorter segment decodes faster and overtakes a longer one that started first,
which was measured, not theorised — five commits with inverted durations
arrived exactly reversed.

What makes it severe rather than untidy is F18. Text at the user's cursor
cannot be revised without backspacing, so an out-of-order commit is not a
glitch that resolves; it is permanent, in the user's document, and it looks
like the transcription was wrong rather than late.

**Mitigation:** commits are serialised through a queue whose ordering is
structural rather than probabilistic — every entry awaits its predecessor, and
entries are only ever created on the main actor in capture order. Any future
path that commits text asynchronously (a post-correction pass, a second
recogniser) goes through the same queue rather than alongside it. **M0.**

---

## 3. Personas and journeys

The design must serve all six. Each entry names what specifically breaks.

### P1 — Maintainer profile: bilingual developer, code-switches constantly

Dictates into an editor, chat, and documents. High tolerance for CLI. Willing
to correct. Zh-en switching is a daily need.

**Journey:** `brew install` → import git log and Messages → dictate day one on
the base model with lexicon biasing already active from the import → fix-last
hotkey throughout week one → post-correction adapter trains at the end of week
two → acoustic adapter considered at month two if the store has enough audio.

**What breaks:** Whisper commits to one language token per window, so
mid-utterance switching is structurally hard on the base model. Day-one
experience for this persona is the weakest of all six. Mitigate with a
documented decoding configuration for mixed input, and set expectations
honestly in the README.

### P2 — Monolingual developer (the largest realistic OSS audience)

Does not care about code-switching at all. Cares about `kubectl`, `nginx`,
library names, and their colleagues' names.

**What breaks:** if enrollment asks about language mix, or the default path
routes through multilingual machinery, we have added friction for the majority
to serve the minority. Multilingual features must be opt-in and invisible when
unused. The default install should be monolingual and fast. This persona is also
the one most likely to contribute code — a bad first experience costs us
contributors.

**Journey:** install → import git log only → dictate → lexicon fills from
corrections → post-correction adapter at week two. Never touches a language
setting.

### P3 — Shared machine, second person, non-technical

A partner or colleague uses the same Mac and login, or borrows it briefly.

**What breaks:** their voice pollutes the training set ([F10](#f10--someone-else-speaks-into-the-mic)),
and they will not use the CLI. Needs speaker verification to quarantine
automatically, plus a GUI profile switch that requires no terminal. If
verification is not ready, at minimum a "pause learning" toggle in the menu
bar.

### P4 — Privacy maximalist

Will not permit audio or mel retention under any circumstances.

**What breaks:** nothing, if the architecture is right — layers 1 and 2
(lexicon and post-correction) need only text pairs. Text-only mode must be a
first-class, fully supported configuration, not a degraded fallback. This
persona gets everything except acoustic adaptation, and should be told exactly
that. Verify at every milestone that text-only mode still works.

### P5 — Multilingual user whose language pair we have not built for

Hindi-English, Tagalog-English, Cantonese-English. No community adapter exists.

**What breaks:** the phonetic-distance filter in
[F1](#f1--revision-mistaken-for-correction) is language-pair specific (pinyin
distance for Mandarin, metaphone for English). If this is hardcoded, supporting
a new pair means surgery. Make the phonetic backend a pluggable per-language
interface from M1, with a documented contract and a fallback (character-level
edit distance) for unsupported languages.

This persona is also the extensibility test for community adapters: they should
be able to run the same training pipeline on their own data and publish the
result. **The pipeline is the product; our adapter is the reference
implementation.**

### P6 — Returning user after a base model upgrade

**Journey:** upgrade lands → app detects base-model change → notifies the user
that text-derived personalization carries over intact, acoustic adaptation must
be rebuilt → `dictate rebuild` runs the retraining → eval gate confirms parity
before the new adapters are promoted.

**What breaks:** if the store was mel-only
([§1.2](#12-audio-retention-format) default), acoustic history is not portable
and must be re-accumulated. Say so clearly at the moment of upgrade, not buried
in docs.

---

## 4. Architecture

```
audio → VAD/segmentation → base ASR (frozen) → contextual biasing
      → post-correction LM → text at cursor
                                    ↓
                      fix-last hotkey / review queue
                                    ↓
                          attribution filter
                                    ↓
                           correction store
                    ↙               ↓               ↘
        lexicon (instant)   post-corr LoRA    acoustic LoRA
                              (nightly)         (monthly, opt-in)
```

### Runtime

MLX for both inference and training — the only Apple Silicon path where they
share a model format. `mlx-tune` already supports STT fine-tuning for Whisper,
Distil-Whisper, Moonshine, Qwen3-ASR, Canary, and Parakeet TDT.

### Correction store schema

Sketch — versioned, SQLite. **This is a sketch, not DDL.** Types and constraints
are deliberately unspecified; settle them when M1 is implemented, and pin the
result behind `schema_version`.

```
utterance:
  id, created_at, schema_version
  base_model_id, adapter_ids (json)
  hypothesis          -- what ASR produced
  final_text          -- after user edits, null if unedited
  correction_source   -- fix_last | review_queue | none
  correction_latency_ms
  phonetic_distance
  attribution         -- correction | revision | quarantined | unedited
  speaker_match_score -- null if verification disabled
  app_bundle_id       -- drives profile selection
  profile_id
  features_path       -- mel or audio, null in text-only mode
  features_kind       -- mel80 | mel128 | opus | none
  holdout             -- bool, permanently reserved from training
```

Everything except `features_path` is base-model-portable. That is deliberate.

### Pluggable interfaces

Define in M1, before implementations proliferate.

- **PhoneticBackend** — `distance(a: str, b: str) -> float`, registered per
  language. Ships with metaphone (en) and pinyin (zh); falls back to
  character-level edit distance.
- **Importer** — `extract(source) -> Iterable[TextSample]`, must filter to the
  user's own content internally. Ships with Telegram JSON export, macOS Messages
  (`chat.db`, `is_from_me = 1`), `git log --author`, and a markdown folder
  walker. WhatsApp export parsing is supported but not the documented happy path
  — the export flow is phone-driven and awkward.
- **Trainer** — `train(store, base_model, config) -> Adapter`, one per layer.

### CLI surface

```
dictate import <importer> <source>
dictate lexicon list | add | remove | canonicalize
dictate review                      # clear the correction queue
dictate train [--layer lexicon|postcorr|acoustic]
dictate eval                        # holdout metrics, gate decision
dictate rebuild                     # regenerate all adapters from store
dictate rollback [--to <version>]
dictate profile list | switch | create
dictate purge [--audio|--all]
dictate doctor                      # versions, config hash, recent eval scores
```

**Naming.** Settled during handoff: the product, repository and Homebrew formula
are `cochlea`; the CLI binary is `dictate`. Formula name and binary name differ,
which Homebrew supports and which has precedent (`ripgrep` installs `rg`). The
brief writes `dictate` throughout, so this records the intent already on the
page rather than changing it.

One check this forces before M0's formula is written: `dictate` is a generic
verb and a plausible collision in `$PATH`. Confirm it is unclaimed in
homebrew-core and by any tool the target audience is likely to have installed.
If it is taken, the binary — not the product — is what gets renamed, and doing
that after an install path exists is a user-visible migration.

---

## 5. Milestones

Each milestone ships. Do not start the next until acceptance criteria pass.

### M0 — Competitive dictation, zero learning

Hotkey capture, VAD segmentation, Whisper via MLX, type at cursor. Model
download on first run with checksum verification. Homebrew formula. Menu bar
presence. No correction capture, no training, no importers.

**Acceptance:** median end-to-end latency under 1s for a 10-second utterance on
M-series, measured warm. First-invocation latency after launch is bounded
separately and must not exceed the warm median by more than a stated margin —
one number cannot cover both, and reporting only the warm median hides exactly
the failure [F19](#f19--model-load-time-on-first-invocation) describes. Works in
a terminal, an editor, and a browser text field without mangling input. Accuracy
indistinguishable from running whisper.cpp directly. Signing and notarization
resolved
([F22](#f22--gatekeeper-blocks-an-unsigned-app-requesting-accessibility-and-full-disk-access)).

### M1 — Correction capture

Fix-last hotkey with audio replay. Review queue UI. Correction store schema.
Attribution filter with the three-signal heuristic. PhoneticBackend interface
with en and zh implementations. Instrumentation for capture rate.

**Acceptance:** a correction made via either path lands in the store with
correct attribution. Quarantined items are surfaceable. We can state the
observed corrections-per-100-words figure from real usage — this number drives
every downstream schedule estimate.

### M2 — Lexicon and biasing

Importer interface plus four implementations. PII stripping and own-messages
filtering. Term extraction (out-of-vocabulary tokens, capitalized non-dictionary
words, repeated n-grams, particle spellings). Orthography variant detection with
canonicalization prompt. Boost injection at decode time with magnitude cap,
negative-signal decay, and unused-entry expiry.

**Acceptance:** importing a git log measurably reduces errors on
project-specific terms. A deliberately-induced over-trigger
([F2](#f2--biasing-over-triggers-and-creates-new-errors)) decays within N
corrections. Text-only mode fully functional. No other participant's text is
ever written to disk.

### M3 — Evaluation harness — must precede any training

Enrollment recording flow (sentences, not paragraphs; targeted phonetic
coverage; one unscripted prompt). Rolling holdout reservation and rotation.
Metrics: corrections per 100 words (primary), entity error rate, WER (reported,
not gating). `dictate eval`, `dictate doctor`, `dictate rollback`. Adapter
versioning and retention.

**Acceptance:** a deliberately corrupted adapter is caught by the gate and
rolled back automatically without user intervention. Holdout items are provably
never seen in training. `dictate doctor` output is sufficient to triage a
regression report.

### M4 — Post-correction LM

LoRA on a small LM (Qwen3 0.6B class) over `(hypothesis, final_text)` pairs.
Replay buffer with fixed correct/corrected ratio. Nightly scheduling gated on
AC, idle, and memory headroom. Resource guard. `dictate rebuild`.
Post-correction disabled in live streaming mode
([F18](#f18--layer-stacking-adds-latency)) — which, since D9, is the shipping
default, so M4 must either earn back the wait or accept that it runs for a
minority of sessions.

**Acceptance:** eval gate passes before promotion, every time, with no manual
step. Latency budget still met. `dictate rebuild` reproduces an equivalent
adapter from the store alone. Training aborts cleanly under memory pressure and
resumes.

### M5 — Acoustic LoRA

Opt-in, default off. Mel feature storage with encryption at rest, retention
caps, backup exclusion, visible storage indicator, one-click purge. Speaker
verification with quarantine. Encoder plus cross-attention LoRA.

**Acceptance:** a second speaker's utterances are quarantined, not trained on.
Retention cap is enforced under sustained heavy use. Purge removes everything,
verifiably. Opting out at any point leaves layers 1 and 2 fully functional.

### M6 — Profiles and community adapters

App-keyed profile selection. Per-profile lexicon and style, shared acoustic
adapter. Formality flag with conservative biasing in formal contexts. Documented
pipeline for training and publishing a community adapter. Adapter registry with
checksums and license metadata.

**Acceptance:** a third party can train and publish an adapter for a new
language pair using only public documentation. License audit complete for every
shipped artifact.

---

## 6. Invariants

Violating any of these is a bug regardless of test results.

1. No adapter is promoted without passing the eval gate.
2. Holdout data is never trained on.
3. Importers discard other participants' content before writing to disk.
4. Text-only mode is fully functional at every milestone.
5. Adapters are rebuildable from the correction store alone.
6. Training never blocks or degrades dictation.
7. Acoustic retention is opt-in and defaults to off.
8. No permission is requested before the feature that needs it is invoked.
9. No training layer ships before its eval gate exists.

### Enforcement

Every invariant except 4 and 9 is a property of one code path or subsystem, and
is tested where that path lives (invariant 6, for example, is enforced by the
resource guard and scheduler that [F20](#f20--training-competes-with-the-users-work)
specifies at M4). Those two need standing enforcement instead, because nothing
in a single milestone's test suite would catch their violation:

- **Invariant 4** (text-only mode) is enforced by the `text-only` job in
  `.github/workflows/ci.yml`, which runs the full suite without the optional
  language extras and re-runs the persona journeys against a minimal install.
  The store additionally refuses acoustic features at the boundary rather than
  merely omitting them, so a violation raises rather than silently persisting. It is vacuous at M0, which has no store. Prose in individual milestone
  acceptance criteria is not sufficient — the brief named text-only mode at M2
  and M5 only, and an invariant that four of seven milestones do not check is
  not an invariant.
- **Invariant 9** was promoted during handoff from the title of
  [M3](#m3--evaluation-harness--must-precede-any-training), which reads "must
  precede any training." Milestone ordering is a plan, and plans slip under
  schedule pressure; an invariant does not. Given that
  [F14](#f14--a-bad-training-run-silently-degrades-the-daily-driver) is
  described as the trust-killing failure, the constraint protecting against it
  should not be enforced only by the order chapters appear in.

---

## 7. Open questions

- **Which base model ships as default?** Whisper turbo is the safe pick;
  SenseVoice-Small is faster and stronger on Mandarin/Cantonese/English but
  non-autoregressive, which changes the biasing implementation. Benchmark both
  at M0.
- **Is speaker verification ([F10](#f10--someone-else-speaks-into-the-mic))
  needed before M5, given P3 exists from day one?** A menu bar "pause learning"
  toggle may be a sufficient M1 stopgap.
- **Realistic capture rate from M1 instrumentation determines whether acoustic
  adaptation is reachable at all for a typical user.** If it is not, M5 becomes
  a power-user feature rather than a headline.

---

## Appendix A: failure mode → milestone traceability

Derived from §2. Nothing here is a new decision — it is the milestone each
entry names, collected so a milestone can be checked off against the failure
modes it is supposed to close.

| ID | Failure mode | Milestone (as stated in §2) |
|----|--------------|------------------------------|
| F1 | Revision mistaken for correction | M1 |
| F2 | Biasing over-triggers, creates new errors | M2 |
| F3 | Catastrophic forgetting | M4 |
| F4 | Survivorship bias in the signal | M4, recurring at M5 † |
| F5 | Homophones cannot be fixed by lexicon | M2 |
| F6 | Inconsistent orthography in user's own data | M2 |
| F7 | Audio/mel store is a rolling record of everything | M5 |
| F8 | Imported chat data contains other people's messages | M2 |
| F9 | Reading `chat.db` looks alarming | M2 |
| F10 | Someone else speaks into the mic | M5 |
| F11 | One adapter cannot serve all contexts | M6 |
| F12 | Profile bleed is asymmetric | M6 |
| F13 | Base model upgrade orphans every adapter | M4 |
| F14 | Bad training run silently degrades daily driver | M3, enforced from M4 |
| F15 | Unreproducible regressions | M3 |
| F16 | Eval set overfitting | M3 |
| F17 | WER is the wrong metric | M3 |
| F18 | Layer stacking adds latency | M4 |
| F19 | Model load time on first invocation | M0 † |
| F20 | Training competes with the user's work | M4 |
| F21 | Homebrew formula cannot ship a 1.6GB model | M0 |
| F22 | Gatekeeper blocks unsigned app | before M0 ships |
| F23 | Licensing on models and data | before any community adapter ships |
| F24 | Scope | M0 |
| F25 | Lexicon fills with words the model already knows | M2 |
| F26 | Asynchronous commits reach the cursor out of order | M0 |

† Assigned during handoff; the brief left these two unnumbered. Reasoning is
recorded at [F4](#f4--survivorship-bias-in-the-signal) and
[F19](#f19--model-load-time-on-first-invocation).

### Per-milestone rollup

| Milestone | Failure modes it must close |
|-----------|------------------------------|
| M0 | F19, F21, F22 (pre-ship), F24 |
| M1 | F1 |
| M2 | F2, F5, F6, F8, F9 |
| M3 | F14 (gate defined), F15, F16, F17 |
| M4 | F3, F4, F13, F14 (gate enforced), F18, F20 |
| M5 | F4 (re-applied), F7, F10 |
| M6 | F11, F12, F23 |

Every failure mode now has a milestone. If a future entry is added without one,
that is the gap to catch in review.

---

## Appendix B: editorial notes on this document

### Transcription changes

This document reproduces the handoff brief. The only changes made while landing
it in the repository were mechanical:

- Restored spaces lost at several `Mitigation:` boundaries (F8, F16, F19, F20,
  F22, F23) and in the P2 and M4 paragraphs.
- Fixed the broken hyphenation in F20 (`not-in-low-power- mode`).
- Changed "The design must serve all five" to "all six" in §3, and the matching
  "weakest of all five" in P1 — the section lists six personas, P1 through P6.
- Added heading anchors, a table of contents, and cross-reference links.

No prose was reworded and no engineering decision was altered, added, or
removed.

### Decisions taken on the handoff read

The brief left six things unresolved. Five are settled here, with reasoning at
the point of change; one is deliberately left to the copyright holder.

**Settled:**

1. **F4 assigned to M4, recurring at M5.** F4 and F3 are one code path — the
   replay buffer's "accepted-as-correct" pool is the un-edited set, and F4's
   sample weight is set where that buffer is composed.
2. **F19 assigned to M0.** Model residency is a process-model decision that
   cannot be retrofitted, and it sits under both M0's latency bar and F24's
   retention argument.
3. **M0 acceptance split into warm and cold latency.** A single "median under
   1s" measured warm hides precisely the first-press failure F19 describes.
   Consequence of decision 2.
4. **Invariant 9 added** — no training layer ships before its eval gate exists.
   Promoted out of M3's title, because milestone ordering is a plan that slips
   and F14 is described as the trust-killing failure.
5. **Naming settled** — product, repository and formula are `cochlea`; the CLI
   binary is `dictate`, as the brief already writes it throughout. Records
   existing intent rather than changing it, and flags the `$PATH` collision
   check that must happen before M0's formula is written.

Decisions 1, 2 and 4 close gaps rather than impose taste: each follows from an
argument the brief itself already makes. Decision 3 follows from 2. Decision 5
ratifies what §4 already assumed.

**Settled subsequently:**

6. **The project license is MIT** (`LICENSE`), on the maintainer's decision.
   The argument is unchanged and worth keeping on the record: Whisper is MIT so
   the default stack carries no copyleft obligation; P2's audience expects
   permissive licensing from a tool in this category; and, most importantly, it
   interacts with F23 — a community adapter trained on a user's own data is
   plausibly a derived work, and a copyleft project license would drag the
   question of what obligations attach to *published adapters* into a pipeline
   whose entire premise (P5) is that third parties publish them freely.

   This does not discharge F23. Model weights and corpora carry their own terms
   independent of the project license, and `LICENSES-MODELS.md` is still
   required before anything that downloads weights is distributed.

### Repository state

The first push landed on an empty repository, which makes
`claude/personalized-dictation-spec-o6s5cn` the repository's default branch —
GitHub assigns the default to the first branch pushed. There is therefore no
`main`, and no pull request has been opened, because there is no base branch to
open one against. The maintainer should rename this branch to `main` (or push a
`main` and repoint the default) before inviting contributors; doing it now is
free, and doing it after forks exist is not. `Formula/cochlea.rb` names `main`
in its `head` stanza and will not resolve until that rename happens.

The repository is **public**.

### Implementation state

The layers that do not require macOS are implemented and tested: the correction
store, the F1 attribution filter, the pluggable phonetic backends, the gitlog
and text importers with PII redaction, and the lexicon — extraction,
persistence, and the token-sequence biasing that reaches the decoder. The persona journeys in
`tests/test_journeys.py` execute P1, P2, P4, P5 and P6 against them.

Running those journeys against a real repository is what surfaced the defects
recorded in the second commit — in particular that homophony and orthographic
variance cannot be derived from a metaphone key, which is a constraint on F5
and F6 that the brief does not anticipate. Both now use explicit rules, and F5's
homophone table is documented as wanting a real pronouncing dictionary.

M3 is also implemented: rolling holdout reservation and rotation, the three
metrics with WER reported but non-gating, the promotion gate, adapter
versioning with retention, and automatic rollback on regression. Its stated
acceptance criterion — a deliberately corrupted adapter caught by the gate and
rolled back with no user intervention — is executed by
`tests/test_adapters.py`. This ordering is deliberate: invariant 9 forbids any
training layer shipping before its gate exists, so M3 is the prerequisite for
M4, M5 and M6 and is the only one of them buildable without Apple Silicon.

The harness takes a `Transcriber` protocol rather than loading a model, which
is what keeps the gate testable on any platform and keeps M3 genuinely ahead of
M4/M5 instead of entangled with them.

M4, M5 and M6 follow the same pattern: the orchestration and policy are built
and tested, and the parts that need Apple Silicon or a model sit behind a
protocol. M4 has the replay buffer, the resource gate and `rebuild` but no
`Trainer`; M5 has retention caps, encryption at rest, speaker-verification
policy and purge but no embedding model; M6 has app-keyed profiles and the F12
formality asymmetry but no community adapter registry.

M0 transcribes. The Swift app builds on Swift 6.2, `SidecarTranscriber`
conforms to `Transcriber` by talking to a Python `mlx-whisper` child process
([D5](DECISIONS.md)), and the chain has been run end to end on an M2 against a
checksum-verified model: 655–661 ms warm per utterance, of which 0–1 ms is the
pipe. `ModelCatalog` is pinned ([D4](DECISIONS.md)).

Three things in this document were falsified by running it on hardware, rather
than by argument, and each is recorded where the reasoning lives:

- **The first-run download could never have succeeded.** The resolver read the
  wrong JSON key, so every file resolved to a nil digest and the downloader
  refused it. Compiling never exercised it and no earlier environment could
  reach the provider. ([D4](DECISIONS.md))
- **§4's shared-format argument does not imply a Swift runtime.** There is no
  Whisper for Swift MLX, and `mlx-tune` is Python — so M5 trains in Python
  whichever way M0 goes. The argument for MLX survives; the argument for Swift
  never existed. ([D5](DECISIONS.md))
- **`large-v3-turbo` misses M0's own latency bar** on an 8 GB M2, by 2x, where
  `whisper-small` meets it. The §7 benchmark is now a command anyone can run
  (`dictate asr-check`). One machine is not enough to reverse
  [D1](DECISIONS.md), and the record says so. ([D6](DECISIONS.md))

**M1 captures corrections.** The fix-last panel is built: one shortcut opens
the last utterance, the correction is repaired in the user's document and
filed through F1's three-signal filter, and the verdict is shown rather than
swallowed — a quarantined correction and a revision look identical to "saved"
otherwise. Repair by backspacing is squared with F18 in
[D11](DECISIONS.md), which also records the bound the app cannot verify: it
cannot see the document, so it withdraws the offer on time and on any
intervening dictation rather than pretending to know the cursor has not moved.
What M1 still owes is the review queue as a screen rather than a CLI command,
and the capture-rate instrument — which cannot report anything until someone
has used it for a while, and that is the number every downstream schedule
estimate depends on.

**M2's mechanism is now wired rather than argued.** `dictate import` writes a
lexicon, `dictate asr-serve` loads it, and the decoder biases towards it —
measured through the shipping path, not a scratch script: "gink's" becomes
"nginx" for about 10 ms on five entries ([D8](DECISIONS.md),
[D10](DECISIONS.md)). The unit is a token sequence, so a phrase is biased in
context and a single word is the one-element case of the same mechanism. What
is missing is the loop back: the sidecar reports which entries won and nothing
reads it, so F2's decay has no negative signal until correction capture (M1)
exists.

The hand-testing that closed T1–T7 also changed what this section can claim.
Six runtime defects were found only by a person holding the key, and two of
them — a stale audio graph blocking the main actor, and a VAD threshold below
the room's own noise floor — could not have been found any other way. What
remains unproven is what streaming and latch activation added: whether text
arrives mid-sentence at the right moments, and whether 0.7 s is where a clause
actually ends. Those are T9 and T10 in [macos/TESTING.md](../macos/TESTING.md),
and no amount of CI will close them either.

The F23 licence audit (`LICENSES-MODELS.md`) is also still outstanding, as is
F22 signing.
