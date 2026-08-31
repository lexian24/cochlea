# cochlea

Dictation that adapts to **you** — your vocabulary, your names, your code-switching,
your spellings. Runs entirely on your machine. No cloud, no account, no telemetry.

[![ci](https://github.com/lexian24/cochlea/actions/workflows/ci.yml/badge.svg)](https://github.com/lexian24/cochlea/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

> ### ⚠️ Status: early. You cannot dictate with this yet.
>
> The **adaptation engine** is built and tested — the correction store, the
> correction/revision filter, phonetic matching, importers, and the lexicon.
>
> The **dictation app** exists only as a first draft in [`macos/`](macos/) that
> **has never been compiled** — it was written on Linux, with no Swift
> toolchain and no Apple Silicon. It also ships no speech model, so it cannot
> transcribe. Treat the Python as the trustworthy half.
>
> `brew install cochlea` does not work yet either — no release has been cut.
> See [docs/RELEASING.md](docs/RELEASING.md) for exactly what's missing.
>
> What you *can* do today is run the CLI, seed a lexicon from your own writing,
> and read [the spec](docs/SPEC.md). If you're here to contribute, the spec is
> the place to start.

---

## Why this exists

Off-the-shelf dictation is trained on everyone, so it's mediocre for anyone in
particular. It mangles your colleagues' names, your project's jargon, the
libraries you use daily, and — if you speak more than one language — most of
what you actually say.

The usual fix is to send your voice to a server that learns from millions of
people. cochlea does the opposite: it learns from one person, on that person's
machine, from corrections they explicitly make.

## How it works

Three adaptation layers, each cheaper and faster than the one below it:

| Layer | Learns from | Updates | Needs audio? |
|-------|-------------|---------|--------------|
| **Lexicon + biasing** | imported text, corrections | instantly | no |
| **Post-correction LM** | `(what ASR heard, what you meant)` pairs | nightly | no |
| **Acoustic adapter** | your voice | monthly, opt-in | yes |

The top two layers need **only text**. If you never let cochlea keep audio, you
still get most of the benefit — that's a supported configuration, not a
degraded one.

```
audio → VAD → ASR (frozen) → contextual biasing → post-correction LM → your cursor
                                       ↓
                        fix-last hotkey / review queue
                                       ↓
                             attribution filter
                                       ↓
                              correction store  ← the durable asset
```

Corrections are captured **only when you explicitly make them** — a fix-last
hotkey or a review queue. cochlea does not watch your text fields. Reading
arbitrary app windows via the Accessibility API would be fragile and would
contradict the whole point.

## Privacy, concretely

- Nothing leaves your machine. There is no server to send it to.
- **Audio retention is off by default.** When enabled, cochlea stores log-mel
  spectrograms, not listenable audio; raw audio requires a separate opt-in.
- Importers read **only your own** messages and commits, and filter before
  anything touches disk — not after.
- No permission is requested until you invoke the feature that needs it.
- `dictate purge` deletes everything.

The [invariants](docs/SPEC.md#6-invariants) list what the code is not allowed to
do regardless of what any test says. Two of them are enforced by CI.

## Try what exists

```sh
git clone https://github.com/lexian24/cochlea && cd cochlea
pip install -e ".[dev]"        # add ,zh for Mandarin support: ".[dev,zh]"
pytest -q                      # 92 tests
```

Seed a lexicon from your own git history — this is the real first step of the
journey, and it works today. Illustrative output from a working codebase:

```console
$ dictate import gitlog . --author you@example.com
imported 412 samples from gitlog:.
  38 terms admitted to the lexicon
    kubectl                  x27
    nginx                    x19
    mlx-tune                 x11
  orthography variant (F6): 'la' x14 vs 'lah' x9
    -- run `dictate lexicon canonicalize` to pick one

$ dictate doctor
cochlea            0.0.1
schema version     1
phonetic backends  en, zh (fallback: edit-distance)
base model         none (M0 not implemented)
```

The evaluation harness works today — it is what gates every future training
run, so it had to exist first:

```console
$ dictate holdout                  # reserve a share, permanently, from training
reserved 5 new item(s) at rotation 'r0'

$ dictate eval                     # holdout metrics and the gate decision
$ dictate adapters                 # versions, and which one is promoted
$ dictate rollback --layer postcorr
```

`dictate train`, `rebuild` and `profile` tell you which milestone they arrive
at rather than failing obscurely.

## Roadmap

| | Milestone | State |
|---|---|---|
| **M0** | Competitive dictation, zero learning | draft Swift, **uncompiled**, no ASR backend |
| **M1** | Correction capture | core built, no UI |
| **M2** | Lexicon and biasing | extraction built, no decode-time biasing |
| **M3** | Evaluation harness — gates all training | **built** (no transcriber to score yet) |
| **M4** | Post-correction LM | not started |
| **M5** | Acoustic adapter (opt-in) | not started |
| **M6** | Profiles and community adapters | not started |

M0 is the gate that matters: if plain dictation isn't competitive with what you
already use, nothing downstream gets a chance. Full criteria in
[the spec](docs/SPEC.md#5-milestones).

## Repository layout

| Path | What it is | Verified? |
|---|---|---|
| `src/cochlea/` | Adaptation engine: store, attribution, phonetics, importers, lexicon, eval harness | yes — 92 tests |
| `macos/` | M0 dictation app (Swift) | **no — never compiled** |
| `Formula/` | Homebrew formula for the CLI | syntax only; not publishable |
| `docs/SPEC.md` | The engineering spec and handoff | — |

## Contributing

Read [docs/SPEC.md](docs/SPEC.md) first — it records the decisions, the failure
modes the design has to survive, and the acceptance criteria for each milestone.
The most useful contributions right now:

- **M0**, the macOS app. The largest gap by far, and it blocks everything.
- **A phonetic backend for your language.** Implement `distance(a, b) -> float`
  and register it; see [`src/cochlea/phonetics.py`](src/cochlea/phonetics.py).
  Unsupported languages fall back to edit distance, so this is additive.
- **An importer.** Implement `extract(source) -> Iterable[TextSample]`, filtering
  to the user's own content *inside* `extract`.

New code must not violate an [invariant](docs/SPEC.md#6-invariants), and
`pytest` must pass with and without the optional `zh` extra.

## Not built here

cochlea does not train a general speech model, does not improve with other
people's data, and will not make an unfamiliar accent work well out of the box.
It makes *your* dictation better on *your* machine by learning what you
personally say. Homophones ("their"/"there") can't be fixed by vocabulary at
all — that's what the post-correction layer is for.

## License

MIT — see [LICENSE](LICENSE). Model weights and training corpora carry their own
terms; per [F23](docs/SPEC.md#f23--licensing-on-models-and-data) each shipped
artifact's license gets recorded in `LICENSES-MODELS.md` before anything is
distributed.
