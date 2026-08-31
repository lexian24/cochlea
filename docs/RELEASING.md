# Releasing, and what still blocks a working `brew install`

## Current state

`brew install cochlea` does **not** work, and cannot yet. Three things are
missing, in order:

1. **No release tag exists.** `Formula/cochlea.rb` carries a placeholder
   `sha256` of all zeros and points at `v0.0.1`, which has never been cut.
   Homebrew refuses a formula whose checksum does not match, so the formula in
   this repository is a template, not an installable package.
2. **No tap exists.** A formula in a repository is not discoverable by
   Homebrew. It needs either a tap repository (`lexian24/homebrew-cochlea`, so
   `brew tap lexian24/cochlea && brew install cochlea`) or acceptance into
   homebrew-core, which has notability requirements this project does not meet
   yet.
3. **The name `dictate` is unverified.** SPEC §4 settles the binary as
   `dictate`, which is a generic verb. Check it is unclaimed in homebrew-core
   and unlikely to collide in a user's `$PATH` *before* the first release —
   renaming after an install path exists is a user-visible migration.

## Cutting a release

```sh
# 1. bump the version
$EDITOR pyproject.toml            # [project] version = "0.1.0"

# 2. tag and push
git tag v0.1.0 && git push origin v0.1.0

# 3. stamp the formula with the real tarball checksum
scripts/stamp-formula.sh v0.1.0

# 4. verify locally before publishing
brew install --build-from-source Formula/cochlea.rb
brew test cochlea
brew audit --strict --new Formula/cochlea.rb
```

`scripts/stamp-formula.sh` fetches the release tarball, computes its SHA-256,
rewrites `url` and `sha256`, and removes the not-publishable banner. It accepts
a local tarball as a second argument for dry runs:

```sh
git archive --format=tar.gz --prefix=cochlea-0.1.0/ HEAD -o /tmp/c.tar.gz
scripts/stamp-formula.sh v0.1.0 /tmp/c.tar.gz
```

## What the formula does and does not install

It installs the `dictate` CLI into a virtualenv. It does **not** install:

- **The macOS app.** The capture path — hotkey, VAD, on-device ASR,
  type-at-cursor, menu bar — is M0 and is not written. Until it exists,
  `dictate` cannot transcribe audio.
- **Model weights.** Per SPEC F21 a formula never ships a 1.6 GB model; models
  download on first run with checksum verification and a resumable transfer.
  That download path is M0 and does not exist either.

## Before the app ships, not after

- **F22, signing and notarization.** An unsigned app requesting Accessibility
  and Full Disk Access is blocked by Gatekeeper. This costs an Apple Developer
  Program membership plus notarization setup, and the spec requires it resolved
  before M0 ships. A Homebrew *cask* (which is how a `.app` is distributed, as
  opposed to the formula here) makes this visible immediately: users hit the
  quarantine prompt on first launch.
- **F23, model licensing.** Whisper is MIT, but Parakeet, SenseVoice, MERaLiON
  and the National Speech Corpus each carry their own terms. Record every
  shipped artifact's license in `LICENSES-MODELS.md` before distributing
  anything that downloads weights.

## One more prerequisite

`Formula/cochlea.rb` declares `head "...", branch: "main"`. This repository has
no `main` — the first push landed on an empty repo, so the working branch became
the default branch. Rename it before publishing the formula, or `brew install
--HEAD` will fail to resolve.
