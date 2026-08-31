"""cochlea — local-only personalized dictation.

This package implements the platform-independent adaptation layers described in
docs/SPEC.md: the correction store, the attribution filter (F1), the pluggable
phonetic backends, importers, and the lexicon.

It does NOT implement the macOS capture path (hotkey, VAD, ASR, type-at-cursor).
That is M0 and requires AppKit, the Accessibility API, and MLX on Apple Silicon.
"""

from importlib.metadata import PackageNotFoundError, version as _version

try:
    #: Single-sourced from package metadata so the installed version and
    #: pyproject.toml cannot drift apart — the Homebrew formula's test block
    #: asserts on this string.
    __version__ = _version("cochlea")
except PackageNotFoundError:      # running from a source tree, not installed
    __version__ = "0.0.0+source"

SCHEMA_VERSION = 1
