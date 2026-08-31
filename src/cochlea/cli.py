"""`dictate` — the CLI surface from SPEC §4.

Only the subcommands whose logic is platform-independent are implemented. The
capture path (hotkey, VAD, ASR, type-at-cursor) is M0 and needs macOS; the
training layers are M4/M5. Unimplemented subcommands say so and name the
milestone rather than failing obscurely.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from . import SCHEMA_VERSION, __version__, phonetics
from .adapters import LAYERS, AdapterRegistry
from .evaluation import HoldoutManager, evaluate, gate
from .profiles import Formality, Profile, ProfileSet
from .retention import FeatureStore, KeyStore, SpeakerVerifier
from .training import ResourceGuard
from .importers import get as get_importer
from .lexicon import Lexicon, HomophoneRejected, detect_variants, extract_terms
from .store import CorrectionStore

NOT_YET = {
    # Orchestration for these exists (see cochlea.training); what is missing is
    # a Trainer implementation, which needs MLX on Apple Silicon, and a
    # Transcriber, which needs M0.
    "train": "M4/M5 -- orchestration built, needs an MLX Trainer",
    "rebuild": "M4 -- orchestration built, needs an MLX Trainer",
    "lexicon": "M2 (extraction works today; persistence does not)",
}


def default_store_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "corrections.db"


def registry_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "adapters.db"


def _registry(args) -> AdapterRegistry:
    return AdapterRegistry(getattr(args, "registry", None) or registry_path())


def _store(args) -> CorrectionStore:
    return CorrectionStore(args.store or default_store_path(),
                           text_only=not args.acoustic)


def cmd_import(args) -> int:
    imp = get_importer(args.importer)
    kwargs = {"author": args.author} if args.author else {}
    try:
        samples = list(imp.extract(args.source, **kwargs))
    except ValueError as e:
        print(f"import failed: {e}", file=sys.stderr)
        return 1
    terms = extract_terms((s.text for s in samples), min_count=args.min_count)
    lx = Lexicon()
    added, rejected = [], []
    for term, count in terms[: args.limit]:
        try:
            lx.add(term)
            added.append((term, count))
        except HomophoneRejected:
            rejected.append(term)
    print(f"imported {len(samples)} samples from {args.importer}:{args.source}")
    print(f"  {len(added)} terms admitted to the lexicon")
    for term, count in added[:20]:
        print(f"    {term:24} x{count}")
    if rejected:
        print(f"  {len(rejected)} rejected as homophones (F5): {', '.join(rejected)}")
    for a, b, ca, cb in detect_variants((s.text for s in samples))[:5]:
        print(f"  orthography variant (F6): {a!r} x{ca} vs {b!r} x{cb} "
              f"-- run `dictate lexicon canonicalize` to pick one")
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
    print("base model         none (M0 not implemented)")
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
    imp.set_defaults(func=cmd_import)

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
