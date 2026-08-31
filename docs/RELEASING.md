# Releasing

## Installing today

```sh
brew tap lexian24/cochlea https://github.com/lexian24/cochlea
brew install cochlea
```

This works now, with no extra repository. The two-argument form of `brew tap`
accepts any git URL, so a repo that is not named `homebrew-cochlea` can still
be a tap, and Homebrew reads formulae from a `Formula/` subdirectory — which is
where `cochlea.rb` lives.

It installs the `dictate` CLI into a virtualenv. It does not install a
dictation app and does not transcribe audio.

### Dropping the URL

To let people type just `brew tap lexian24/cochlea`, the tap must live in a
repository literally named `homebrew-cochlea`:

```sh
gh repo create lexian24/homebrew-cochlea --public --clone
cp Formula/cochlea.rb homebrew-cochlea/Formula/
cd homebrew-cochlea && git add -A && git commit -m "cochlea 0.1.0" && git push
```

Keeping the formula in this repo and copying on release is the simpler
arrangement while there is one formula.

### `brew install --cask cochlea`

That is the form [Vorssaint](https://github.com/vorssaintapp/vorssaint-utils)
uses, and it is where this should end up — but a cask installs a `.app`, and
there isn't one. [`Casks/cochlea.rb`](../Casks/cochlea.rb) is written and
records the three blockers: `macos/` must compile, the app must be signed and
notarized (F22), and a release must carry a `.dmg`. Acceptance into
homebrew-cask, so no tap is needed at all, additionally requires meeting their
notability threshold.

### Why the formula pins a commit, not a tag

`Formula/cochlea.rb` points at
`https://github.com/lexian24/cochlea/archive/<commit>.tar.gz`.

The environment this was released from could not create tags — GitHub answered
`403` to every push to `refs/tags/*`, while branch pushes succeeded. A commit
tarball is immutable, so the pinned `sha256` stays valid indefinitely; the only
thing lost is that Homebrew cannot infer a version from the URL, so `version`
is declared explicitly.

**This is worth converting to a tag** when someone with tag permission gets to
it, because a tag is what people expect to see and what release tooling reads:

```sh
git tag -a v0.1.0 -m "cochlea 0.1.0" && git push origin v0.1.0
scripts/stamp-formula.sh v0.1.0        # rewrites url + sha256 for the tag
```

One caveat that applies to both forms: GitHub's auto-generated archives are not
contractually byte-stable. They have been stable for years and homebrew-core
depends on it, but an upstream change to the archiver would invalidate the
checksum. Uploading a release asset built with `git archive` avoids this
entirely and is the right move before this has real users.

### A tap, if you want the short command

`brew install cochlea` (no URL) needs a tap repository named
`lexian24/homebrew-cochlea` containing `Formula/cochlea.rb`. Then:

```sh
brew tap lexian24/cochlea
brew install cochlea
```

Nothing else changes; the formula file is the same.

## Verifying a release

What was actually run against this formula, from a clean directory:

1. Fetched the URL the formula names and confirmed the `sha256` matches.
2. Extracted it, built a fresh virtualenv, `pip install .`.
3. Ran every assertion in the formula's `test do` block against the installed
   binary: version string, `doctor` output, that a fresh install defaults to
   **text-only** (invariant 7), and that an unimplemented subcommand reports
   its milestone and exits 2.
4. Confirmed the bundled word list ships inside the package.

On a Mac, the equivalent is:

```sh
brew install --build-from-source Formula/cochlea.rb
brew test cochlea
brew audit --strict --new Formula/cochlea.rb
```

`brew audit` has not been run — Homebrew does not exist on the machine this was
built on. Expect it to have opinions about the commit-pinned URL.

## The binary name

The formula installs `dictate`, which is a generic verb and a plausible `$PATH`
collision. It is unclaimed in homebrew-core as far as this repository knows,
but that has not been checked against a live index. Check before promoting this
beyond a URL install — renaming after people have it installed is a migration.

## Cutting the next release

```sh
$EDITOR pyproject.toml                 # bump [project] version
git commit -am "Release 0.2.0" && git push origin main
scripts/stamp-formula.sh v0.2.0        # or re-pin the new commit
```

`__version__` is read from package metadata, so `pyproject.toml` is the single
source and the formula's version assertion cannot drift from it.

## What the formula does not install

- **The macOS app.** M0 is an uncompiled Swift draft. A `.app` ships through a
  Homebrew **cask**, not this formula.
- **Model weights.** Per F21 a formula never ships a 1.6 GB model. The default
  model is decided ([D1](DECISIONS.md)) and its checksums are now pinned
  ([D4](DECISIONS.md)), but no ASR backend exists yet, so nothing consumes the
  download.

## Still blocking a real product release

- **F22, signing and notarization.** An unsigned app requesting Accessibility
  and Microphone access is blocked by Gatekeeper. Required before M0 ships.
- **F23, model licensing.** Whisper is MIT, which is why it was chosen, but
  `LICENSES-MODELS.md` still has to exist before anything downloads weights.
- **An ASR backend.** Nothing conforms to `Transcriber`, so the app cannot
  transcribe. See [macos/BUILDING.md](../macos/BUILDING.md).

Checksum pinning, which stood here as a blocker under D2, is done
([D4](DECISIONS.md)).
