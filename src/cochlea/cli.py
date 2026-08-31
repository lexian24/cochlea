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
from .importers import get as get_importer
from .lexicon import Lexicon, HomophoneRejected, detect_variants, extract_terms
from .store import CorrectionStore

NOT_YET = {
    "train": "M4 (post-correction) / M5 (acoustic)",
    "eval": "M3",
    "rebuild": "M4",
    "rollback": "M3",
    "profile": "M6",
    "lexicon": "M2 (extraction works today; persistence does not)",
}


def default_store_path() -> Path:
    base = Path(os.environ.get("COCHLEA_HOME", Path.home() / ".cochlea"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "corrections.db"


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


def cmd_doctor(args) -> int:
    store_path = args.store or default_store_path()
    print(f"cochlea            {__version__}")
    print(f"python             {sys.version.split()[0]}")
    print(f"schema version     {SCHEMA_VERSION}")
    print(f"store              {store_path} ({'present' if Path(store_path).exists() else 'absent'})")
    print(f"phonetic backends  {', '.join(phonetics.available())} (fallback: edit-distance)")
    print(f"importers          {', '.join(sorted(__import__('cochlea.importers', fromlist=['REGISTRY']).REGISTRY))}")
    print("base model         none (M0 not implemented)")
    print("adapters           none (M4/M5 not implemented)")
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
