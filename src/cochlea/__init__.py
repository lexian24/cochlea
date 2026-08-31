"""cochlea — local-only personalized dictation.

This package implements the platform-independent adaptation layers described in
docs/SPEC.md: the correction store, the attribution filter (F1), the pluggable
phonetic backends, importers, and the lexicon.

It does NOT implement the macOS capture path (hotkey, VAD, ASR, type-at-cursor).
That is M0 and requires AppKit, the Accessibility API, and MLX on Apple Silicon.
"""

__version__ = "0.0.1"
SCHEMA_VERSION = 1
