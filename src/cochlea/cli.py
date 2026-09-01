"""`dictate` — the CLI surface from SPEC §4.

Only the subcommands whose logic is platform-independent are implemented. The
capture path (hotkey, VAD, ASR, type-at-cursor) is M0 and needs macOS; the
training layers are M4/M5. Unimplemented subcommands say so and name the
milestone rather than failing obscurely.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import SCHEMA_VERSION, __version__, phonetics
from .adapters import LAYERS, AdapterRegistry
from .attribution import classify
from .evaluation import HoldoutManager, evaluate, gate
from .profiles import Formality, Profile, ProfileSet
from .retention import FeatureStore, KeyStore, SpeakerVerifier
from .training import ResourceGuard
from .importers import get as get_importer
from .lexicon import (Lexicon, HomophoneRejected, detect_variants,
                      extract_phrases, extract_terms, terms_from_correction)
from .attribution import CORRECTION, QUARANTINED, REVISION
from .store import CorrectionStore, Utterance

NOT_YET = {
    # Orchestration for these exists (see cochlea.training); what is missing is
    # a Trainer implementation, which needs MLX on Apple Silicon, and a
    # Transcriber, which needs M0.
    "train": "M4/M5 -- orchestration built, needs an MLX Trainer",
    "rebuild": "M4 -- orchestration built, needs an MLX Trainer",
}


def default_store_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "corrections.db"


def lexicon_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "lexicon.json"


def registry_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "adapters.db"


def _registry(args) -> AdapterRegistry:
    return AdapterRegistry(getattr(args, "registry", None) or registry_path())


def _store(args) -> CorrectionStore:
    path = args.store or default_store_path()
    # `default_store_path` creates its directory; an explicit `--store` did
    # not, so pointing at one that does not exist yet failed with a bare
    # sqlite3 "unable to open database file" -- which names neither the path
    # nor the reason.
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    return CorrectionStore(path, text_only=not args.acoustic)


def cmd_import(args) -> int:
    """Seed the lexicon from the user's own writing.

    Two phases, and the split is deliberate. Nothing is written until
    ``--commit``, so the first run is a proposal the user reads: this is text
    lifted out of their private messages, and the least a tool can do before
    keeping any of it is show them exactly what it took. It also means a bad
    ``--min-count`` costs a re-run rather than a lexicon full of noise.
    """
    imp = get_importer(args.importer)
    kwargs = {"author": args.author} if args.author else {}
    try:
        samples = list(imp.extract(args.source, **kwargs))
    except ValueError as e:
        if args.json:
            # The speaker list travels with the error, not just in the
            # message. A GUI that has to regex an English sentence to find out
            # who is in the file will break the first time the sentence is
            # reworded.
            payload = {"error": str(e)}
            if speakers := getattr(e, "speakers", None):
                payload["speakers"] = [{"name": n, "lines": c} for n, c in speakers]
            if candidates := getattr(e, "candidates", None):
                payload["speakers"] = [{"name": n, "lines": c} for n, c in candidates]
            print(json.dumps(payload))
            return 1
        print(f"import failed: {e}", file=sys.stderr)
        return 1

    texts = [s.text for s in samples]
    terms = extract_terms(texts, min_count=args.min_count)
    # Phrases as well as words, because a phrase is what biasing is actually
    # good at: "pull request" as one entry lifts "request" only after "pull",
    # where two word entries lift it in every sentence the user speaks. The
    # threshold is higher than for terms -- a word can be distinctive on one
    # sighting, a word *sequence* has to recur before it is a habit.
    phrases = ([] if args.no_phrases
               else extract_phrases(texts, min_count=max(args.min_count, 3),
                                    max_words=args.max_words))

    lexicon = Lexicon.load(lexicon_path()) if args.commit else Lexicon()
    before = set(lexicon.entries)
    added, rejected = [], []
    for entry, count in list(terms)[: args.limit] + list(phrases)[: args.limit]:
        try:
            lexicon.add(entry)
            added.append((entry, count))
        except HomophoneRejected:
            rejected.append(entry)

    words = [(t, c) for t, c in added if " " not in t]
    multi = [(t, c) for t, c in added if " " in t]
    variants = [{"a": a, "b": b, "count_a": ca, "count_b": cb}
                for a, b, ca, cb in detect_variants(texts)[:5]]

    if args.json:
        if args.commit:
            lexicon.save(lexicon_path())
        print(json.dumps({
            "samples": len(samples),
            "source": f"{args.importer}:{args.source}",
            "terms": [{"term": t, "count": c} for t, c in words],
            "phrases": [{"term": t, "count": c} for t, c in multi],
            "rejected": rejected,
            "variants": variants,
            "committed": bool(args.commit),
            "entries": len(lexicon.entries),
            "path": str(lexicon_path()),
        }))
        return 0

    print(f"imported {len(samples)} samples from {args.importer}:{args.source}")
    print(f"  {len(words)} terms, {len(multi)} phrases")
    for label, group in (("term", words), ("phrase", multi)):
        for entry, count in group[:20]:
            mark = " " if entry in before else "+"
            print(f"    {mark} {label:6} {entry:28} x{count}")
    if rejected:
        print(f"  {len(rejected)} rejected as homophones (F5): {', '.join(rejected)}")
    for v in variants:
        print(f"  orthography variant (F6): {v['a']!r} x{v['count_a']} vs "
              f"{v['b']!r} x{v['count_b']} -- run "
              f"`dictate lexicon canonicalize {v['a']} {v['b']}` to pick one")

    if not args.commit:
        print("\nNothing was written. Re-run with --commit to keep this.")
        return 0
    path = lexicon.save(lexicon_path())
    print(f"\nwrote {len(lexicon.entries)} entries to {path}")
    print("Dictation picks it up when the app next starts the ASR helper.")
    return 0


def cmd_lexicon(args) -> int:
    """Read and edit what dictation is biased towards."""
    path = lexicon_path()
    lexicon = Lexicon.load(path)

    if args.action == "list":
        if not lexicon.entries:
            print(f"no lexicon at {path}\n"
                  "Seed one with `dictate import <importer> <source> --commit`.")
            return 0
        print(f"{len(lexicon.entries)} entries in {path}\n")
        rows = sorted(lexicon.entries.values(),
                      key=lambda e: (-e.hits, e.term))
        print(f"  {'entry':30} {'boost':>6} {'logits':>7} {'hits':>5} {'rejected':>9}")
        for e in rows:
            print(f"  {e.term:30} {e.boost:6.2f} "
                  f"{_logit_boost(e.boost):7.1f} {e.hits:5} {e.rejections:9}")
        return 0

    if args.action == "add":
        if not args.terms:
            print("nothing to add", file=sys.stderr)
            return 1
        for term in args.terms:
            try:
                lexicon.add(term, boost=args.boost)
                print(f"  + {term}")
            except HomophoneRejected as exc:
                print(f"  rejected {term}: {exc}", file=sys.stderr)
        lexicon.save(path)
        return 0

    if args.action == "remove":
        for term in args.terms:
            lexicon.remove(term)
            print(f"  - {term}")
        lexicon.save(path)
        return 0

    if args.action == "canonicalize":
        if len(args.terms) != 2:
            print("canonicalize takes exactly two arguments: variant canonical",
                  file=sys.stderr)
            return 1
        variant, canonical = args.terms
        lexicon.canonicalize(variant, canonical)
        lexicon.save(path)
        print(f"  {variant!r} will be rewritten to {canonical!r} (F6)")
        return 0

    if args.action == "expire":
        dead = lexicon.expire()
        lexicon.save(path)
        print(f"  expired {len(dead)} unused entries" + (f": {', '.join(dead)}" if dead else ""))
        return 0

    print(f"unknown action {args.action!r}", file=sys.stderr)
    return 1


def _logit_boost(strength: float) -> float:
    """Imported lazily: `cochlea.biasing` reaches the phonetics stack."""
    from .biasing import logit_boost

    return logit_boost(strength)


def cmd_correct(args) -> int:
    """Record one correction, with the F1 filter applied.

    The app calls this after the fix-last panel. Attribution is decided here
    rather than in Swift for the same reason extraction is: F1's three-signal
    heuristic is one rule, and a second implementation would be two that have
    to agree forever.
    """
    verdict = classify(
        args.hypothesis,
        args.final,
        correction_source=args.source,
        latency_ms=args.latency_ms,
        language=args.language,
    )
    store = _store(args)
    utterance = Utterance(
        hypothesis=args.hypothesis,
        final_text=args.final,
        base_model_id=args.model or "unknown",
        correction_source=args.source,
        correction_latency_ms=args.latency_ms,
        phonetic_distance=verdict.phonetic_distance,
        attribution=verdict.attribution,
        app_bundle_id=args.app,
    )
    utterance_id = store.add(utterance)

    # M1 -> M2. A correction that only lands in the store does nothing the
    # user can feel: it waits for a trainer that does not exist yet, and the
    # next utterance mishears the same word again. Biasing needs no training,
    # so the word they just typed by hand can be in force on the next
    # sentence.
    #
    # Gated on the F1 verdict, not on the text. A revision is someone changing
    # their mind, and the words they changed it to are not evidence of
    # anything the recogniser got wrong -- learning from those is how a
    # lexicon fills with the user's whole vocabulary instead of the part that
    # needs help (F25).
    learned: list[str] = []
    if not args.no_learn and verdict.attribution == CORRECTION:
        lexicon = Lexicon.load(lexicon_path())
        for term in terms_from_correction(args.hypothesis, args.final,
                                          language=args.language):
            try:
                lexicon.add(term)
                learned.append(term)
            except HomophoneRejected:
                pass                       # F5, already filtered, belt and braces
        if learned:
            lexicon.save(lexicon_path())

    if args.json:
        print(json.dumps({
            "id": utterance_id,
            "attribution": verdict.attribution,
            "phonetic_distance": verdict.phonetic_distance,
            "reason": verdict.reason,
            "failed_signals": verdict.failed,
            "learned": learned,
        }))
        return 0
    print(f"recorded {utterance_id[:8]} as {verdict.attribution}")
    print(f"  {verdict.reason}")
    if verdict.failed:
        print(f"  failed signals: {', '.join(verdict.failed)}")
    # Three outcomes, three different consequences, and saying "quarantined"
    # for all of them was wrong: a revision is filed and never trained on,
    # only a quarantine waits for a person.
    if learned:
        print(f"  added to your lexicon: {', '.join(learned)}")
        print("  in force the next time the ASR helper starts")
    if verdict.attribution == QUARANTINED:
        print("  waiting for adjudication (F1) -- `dictate review`")
    elif verdict.attribution == REVISION:
        print("  kept, but never trained on: this reads as a change of mind, "
              "not an ASR error (F1)")
    return 0


def cmd_review(args) -> int:
    store = _store(args)
    queue = store.review_queue()
    if not queue:
        print("review queue empty")
        return 0
    print(f"{len(queue)} quarantined utterance(s) awaiting adjudication (F1):\n")
    for row in queue:
        print(f"  [{row['id'][:8]}] heard : {row['hypothesis']}")
        print(f"             typed : {row['final_text']}")
        print(f"             phonetic distance {row['phonetic_distance']}\n")
    return 0


def cmd_stats(args) -> int:
    store = _store(args)
    rows = store.all()
    print(f"store              {args.store or default_store_path()}")
    print(f"schema version     {SCHEMA_VERSION}")
    print(f"mode               {'acoustic enabled' if args.acoustic else 'text-only'}")
    print(f"utterances         {len(rows)}")
    print(f"  trainable        {len(store.training_set())}")
    print(f"  holdout          {len(store.holdout_set())}")
    print(f"  quarantined      {len(store.review_queue())}")
    print(f"corrections/100w   {store.corrections_per_100_words():.2f}   (primary metric, F17)")
    return 0


def cmd_purge(args) -> int:
    store = _store(args)
    n = store.purge(audio_only=args.audio)
    print(f"purged {n} row(s){' (acoustic features only)' if args.audio else ''}")
    return 0


def cmd_holdout(args) -> int:
    store = _store(args)
    reserved = HoldoutManager(store, fraction=args.fraction,
                              salt=args.salt).reserve()
    total = len(store.holdout_set())
    print(f"reserved {len(reserved)} new item(s) at rotation {args.salt!r}")
    print(f"holdout now {total} of {len(store.all())} utterance(s)")
    print("Reservation is permanent: these are never trained on (invariant 2).")
    return 0


def cmd_eval(args) -> int:
    """Score the current adapters against the holdout.

    Without a transcriber there is nothing to score, and M3 deliberately does
    not depend on M4/M5 to be testable -- so this reports the gate's readiness
    rather than inventing a result.
    """
    store = _store(args)
    held = store.holdout_set()
    reg = _registry(args)
    print(f"holdout            {len(held)} item(s)")
    if len(held) < args.min_holdout:
        print(f"gate               NOT READY -- need at least {args.min_holdout} "
              f"holdout items to decide")
        print("                   run `dictate holdout` after more corrections land")
    else:
        print("gate               ready")
    for layer in LAYERS:
        cur = reg.current(layer)
        if cur is None:
            print(f"{layer:18} no promoted adapter")
        else:
            score = cur.eval.as_dict() if cur.eval else "no score recorded"
            print(f"{layer:18} v{cur.version} ({cur.id})  {score}")
    print()
    print("No transcriber is wired up: base ASR is M0 and the trained layers are")
    print("M4/M5. `dictate eval` scores real adapters once those exist.")
    return 0


def cmd_rollback(args) -> int:
    reg = _registry(args)
    restored = reg.rollback(args.layer, to_version=args.to)
    if restored is None:
        print(f"no earlier {args.layer} adapter to roll back to", file=sys.stderr)
        return 1
    print(f"rolled {args.layer} back to v{restored.version} ({restored.id})")
    return 0


def cmd_adapters(args) -> int:
    reg = _registry(args)
    any_found = False
    for layer in LAYERS:
        history = reg.history(layer)
        if not history:
            continue
        any_found = True
        print(f"{layer}:")
        for a in history:
            mark = "*" if a.promoted else " "
            print(f"  {mark} v{a.version:<3} {a.id:34} base={a.base_model_id} "
                  f"cfg={a.config_hash}")
    if not any_found:
        print("no adapters registered (training lands at M4/M5)")
    return 0


def cmd_profile(args) -> int:
    """M6. Profiles are in-memory until persistence lands with the lexicon."""
    ps = ProfileSet()
    ps.add(Profile(name="work", formality=Formality.FORMAL,
                   app_patterns=["com.apple.mail", "com.microsoft.Outlook"]))
    ps.add(Profile(name="chat", formality=Formality.CASUAL,
                   app_patterns=["com.tinyspeck.*", "com.apple.MobileSMS"]))
    if args.action == "list":
        for name in ps.names():
            p = ps.get(name)
            patterns = ", ".join(p.app_patterns) or "(fallback)"
            print(f"  {name:10} {p.formality:7} {patterns}")
        print()
        print("One acoustic adapter is shared across all profiles: the voice")
        print("does not change with context (SPEC F11).")
    elif args.action == "which":
        selected = ps.select(args.bundle_id)
        print(f"{args.bundle_id or '(none)'} -> {selected.name} ({selected.formality})")
    return 0


def cmd_guard(args) -> int:
    """Show whether a training run would be allowed to start right now (F20)."""
    guard = ResourceGuard(
        on_ac_power=not args.on_battery,
        idle_seconds=args.idle_seconds,
        low_power_mode=args.low_power,
        available_memory_gb=args.free_memory_gb,
    )
    blockers = guard.blockers()
    if blockers:
        print("training would be DEFERRED:")
        for b in blockers:
            print(f"  - {b}")
    else:
        print("training would be allowed to start")
    print()
    print("Training never blocks dictation and is always resumable "
          "(SPEC invariant 6, F20).")
    return 0 if not blockers else 1


def cmd_doctor(args) -> int:
    store_path = args.store or default_store_path()
    print(f"cochlea            {__version__}")
    print(f"python             {sys.version.split()[0]}")
    print(f"schema version     {SCHEMA_VERSION}")
    print(f"store              {store_path} ({'present' if Path(store_path).exists() else 'absent'})")
    print(f"phonetic backends  {', '.join(phonetics.available())} (fallback: edit-distance)")
    print(f"importers          {', '.join(sorted(__import__('cochlea.importers', fromlist=['REGISTRY']).REGISTRY))}")
    from . import asr as _asr
    print(f"asr backend        {_asr.describe()}")
    if Path(store_path).exists():
        st = CorrectionStore(store_path, text_only=not args.acoustic)
        print(f"utterances         {len(st.all())} "
              f"({len(st.holdout_set())} holdout, {len(st.review_queue())} quarantined)")
        print(f"corrections/100w   {st.corrections_per_100_words():.3f}")
    reg = _registry(args)
    printed = False
    for layer in LAYERS:
        cur = reg.current(layer)
        if cur is not None:
            printed = True
            ev = cur.eval.as_dict() if cur.eval else {}
            print(f"adapter {layer:10} v{cur.version} id={cur.id} "
                  f"base={cur.base_model_id} cfg={cur.config_hash}")
            print(f"                   eval={ev}")
    if not printed:
        print("adapters           none promoted (M4/M5 not implemented)")
    print()
    print("Paste this into a bug report: it carries the adapter version, base")
    print("model, config hash and eval score a regression needs (SPEC F15).")
    return 0


def cmd_asr_serve(args) -> int:
    """Speak the sidecar protocol on stdin/stdout until the app closes the pipe.

    Not a user-facing command. The macOS app spawns this and talks to it (D5);
    running it by hand gets you a process waiting for JSON on stdin, which is
    why it is hidden from `dictate --help`.
    """
    from .sidecar import serve

    # Loaded here rather than in `serve`, so the sidecar stays a pure protocol
    # implementation and the tests can drive it without a filesystem.
    lexicon = None if args.no_lexicon else Lexicon.load(lexicon_path())
    return serve(args.model, identifier=args.identifier,
                 lexicon=lexicon if lexicon and lexicon.entries else None)


def cmd_asr_check(args) -> int:
    """Transcribe a 16 kHz mono WAV and report the latency split.

    This is the M0 benchmark SPEC §7 asked for, runnable by anyone on their own
    machine: F19 makes cold and warm separate acceptance numbers, and the only
    way to know which model meets the budget on *your* hardware is to measure
    it there. See D6 for what it reported on the machine it was written on.
    """
    import time
    import wave

    from .asr import ASRUnavailable, MLXWhisperBackend, SAMPLE_RATE

    try:
        with wave.open(args.audio, "rb") as w:
            if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1:
                print(f"expected 16 kHz mono, got {w.getframerate()} Hz "
                      f"{w.getnchannels()}ch", file=sys.stderr)
                return 1
            frames, width = w.readframes(w.getnframes()), w.getsampwidth()
    except (OSError, wave.Error) as exc:
        print(f"could not read {args.audio}: {exc}", file=sys.stderr)
        return 1
    if width != 2:
        print(f"expected 16-bit samples, got {width * 8}-bit", file=sys.stderr)
        return 1

    import array

    pcm = array.array("h")
    pcm.frombytes(frames)
    if sys.byteorder != "little":
        pcm.byteswap()
    samples = [v / 32768.0 for v in pcm]
    seconds = len(samples) / SAMPLE_RATE

    # Biasing is measured against the same audio in the same process, because
    # its cost is the thing worth knowing: D8 put 400 entries at +27%, and
    # whether that fits the budget depends on the machine as much as D6's model
    # choice does.
    lexicon = Lexicon.load(lexicon_path()) if args.lexicon else None
    if args.lexicon and not (lexicon and lexicon.entries):
        print(f"no lexicon at {lexicon_path()}; measuring unbiased",
              file=sys.stderr)
        lexicon = None

    try:
        backend = MLXWhisperBackend(args.model, fp16=not args.fp32)
        started = time.perf_counter()
        backend.warm_up()
        cold_ms = int((time.perf_counter() - started) * 1000)
        runs = []
        for _ in range(args.runs):
            runs.append(backend.transcribe(samples, language=args.language,
                                           lexicon=lexicon))
    except ASRUnavailable as exc:
        print(f"asr unavailable: {exc}", file=sys.stderr)
        return 1

    warm = sorted(r.inference_ms for r in runs)[len(runs) // 2]
    print(f"model              {backend.identifier}")
    print(f"precision          {'fp16' if backend.fp16 else 'fp32'}")
    print(f"audio              {seconds:.2f}s")
    print(f"cold (weight load) {cold_ms} ms")
    print(f"warm median        {warm} ms   over {args.runs} run(s)")
    print(f"budget             {'MET' if warm < 1000 else 'MISSED'} "
          f"(M0 acceptance: under 1000 ms warm)")
    if lexicon is not None:
        print(f"lexicon            {len(lexicon.entries)} entries")
        hits = sorted({t for r in runs for t in r.biased_terms})
        print(f"biased terms hit   {', '.join(hits) if hits else '(none)'}")
    print(f"language           {runs[-1].language}")
    print(f"text               {runs[-1].text}")
    print()
    print("Cold and warm are reported separately because F19 makes them "
          "separate\nacceptance numbers; one median hides the first-press cost.")
    return 0 if warm < 1000 else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="dictate", description=__doc__.splitlines()[0])
    p.add_argument("--version", action="version", version=f"cochlea {__version__}")
    p.add_argument("--store", help="path to the correction store")
    p.add_argument("--acoustic", action="store_true",
                   help="allow acoustic features (default off, SPEC invariant 7)")
    sub = p.add_subparsers(dest="cmd", required=True)

    imp = sub.add_parser("import", help="import text to seed the lexicon")
    imp.add_argument("importer")
    imp.add_argument("source")
    imp.add_argument("--author", help="override the identity to filter on")
    imp.add_argument("--min-count", type=int, default=2)
    imp.add_argument("--limit", type=int, default=200)
    imp.add_argument("--max-words", type=int, default=4,
                     help="longest phrase to consider")
    imp.add_argument("--no-phrases", action="store_true",
                     help="single terms only")
    imp.add_argument("--commit", action="store_true",
                     help="write to the lexicon; without it this only proposes")
    imp.add_argument("--json", action="store_true",
                     help="machine-readable output, for the app")
    imp.set_defaults(func=cmd_import)

    lx = sub.add_parser("lexicon", help="read and edit what dictation is biased towards")
    lx.add_argument("action", nargs="?", default="list",
                    choices=["list", "add", "remove", "canonicalize", "expire"])
    lx.add_argument("terms", nargs="*")
    lx.add_argument("--boost", type=float, default=1.5,
                    help="strength, 1.0 is neutral (default 1.5 = 6 logits, D8)")
    lx.set_defaults(func=cmd_lexicon)

    cor = sub.add_parser("correct", help="record one correction (the app calls this)")
    cor.add_argument("--hypothesis", required=True, help="what was transcribed")
    cor.add_argument("--final", required=True, help="what the user meant")
    cor.add_argument("--latency-ms", type=int,
                     help="how long after the text appeared the fix was made")
    cor.add_argument("--source", default="fix_last",
                     choices=["fix_last", "review_queue"])
    cor.add_argument("--app", help="bundle identifier of the app being typed into")
    cor.add_argument("--model", help="base model that produced the hypothesis")
    cor.add_argument("--language", default="en")
    cor.add_argument("--no-learn", action="store_true",
                     help="file the correction without adding terms to the lexicon")
    cor.add_argument("--json", action="store_true")
    cor.set_defaults(func=cmd_correct)

    sub.add_parser("review", help="show the correction queue").set_defaults(func=cmd_review)

    hp = sub.add_parser("holdout", help="reserve a share of corrections from training")
    hp.add_argument("--fraction", type=float, default=0.15)
    hp.add_argument("--salt", default="r0", help="rotation label (F16)")
    hp.set_defaults(func=cmd_holdout)

    ev = sub.add_parser("eval", help="holdout metrics and gate decision")
    ev.add_argument("--min-holdout", type=int, default=5)
    ev.set_defaults(func=cmd_eval)

    rb = sub.add_parser("rollback", help="restore a previous adapter")
    rb.add_argument("--layer", default="postcorr", choices=LAYERS)
    rb.add_argument("--to", type=int, help="version number")
    rb.set_defaults(func=cmd_rollback)

    sub.add_parser("adapters", help="adapter versions and which is promoted"
                   ).set_defaults(func=cmd_adapters)

    pr = sub.add_parser("profile", help="app-keyed profiles (M6)")
    pr.add_argument("action", choices=["list", "which"], default="list", nargs="?")
    pr.add_argument("bundle_id", nargs="?", help="for `which`: a bundle identifier")
    pr.set_defaults(func=cmd_profile)

    gd = sub.add_parser("guard", help="would a training run start right now? (F20)")
    gd.add_argument("--on-battery", action="store_true")
    gd.add_argument("--low-power", action="store_true")
    gd.add_argument("--idle-seconds", type=float, default=3600)
    gd.add_argument("--free-memory-gb", type=float, default=16.0)
    gd.set_defaults(func=cmd_guard)
    sub.add_parser("stats", help="store metrics").set_defaults(func=cmd_stats)
    sub.add_parser("doctor", help="versions and config").set_defaults(func=cmd_doctor)

    # M0's ASR path (D5). asr-serve is spawned by the app, not typed.
    serve_p = sub.add_parser("asr-serve", help=argparse.SUPPRESS)
    serve_p.add_argument("--model", required=True,
                         help="directory holding config.json and the weights")
    serve_p.add_argument("--identifier", help="name to report to the app")
    serve_p.add_argument("--no-lexicon", action="store_true",
                         help="decode without contextual biasing")
    serve_p.set_defaults(func=cmd_asr_serve)

    chk = sub.add_parser("asr-check", help="benchmark ASR on a 16 kHz mono WAV")
    chk.add_argument("audio")
    chk.add_argument("--model", required=True,
                     help="directory holding config.json and the weights")
    chk.add_argument("--language", help="force a language instead of detecting")
    chk.add_argument("--runs", type=int, default=3)
    chk.add_argument("--fp32", action="store_true",
                     help="full precision; roughly halves throughput (D6)")
    chk.add_argument("--lexicon", action="store_true",
                     help="bias towards ~/.cochlea/lexicon.json and report the cost")
    chk.set_defaults(func=cmd_asr_check)

    pur = sub.add_parser("purge", help="delete stored data")
    pur.add_argument("--audio", action="store_true", help="acoustic features only")
    pur.set_defaults(func=cmd_purge)

    for name, milestone in NOT_YET.items():
        sp = sub.add_parser(name, help=f"not implemented (lands at {milestone})")
        sp.add_argument("rest", nargs=argparse.REMAINDER)
        sp.set_defaults(func=lambda a, _n=name, _m=milestone: (
            print(f"`dictate {_n}` is not implemented yet; it lands at {_m}. "
                  f"See docs/SPEC.md.", file=sys.stderr) or 2))

    # Stub subcommands accept (and ignore) the flags the SPEC documents for
    # them, so `dictate train --layer acoustic` reports the milestone rather
    # than an argparse error about --layer.
    args, extra = p.parse_known_args(argv)
    if extra and args.cmd not in NOT_YET:
        p.error(f"unrecognized arguments: {' '.join(extra)}")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
