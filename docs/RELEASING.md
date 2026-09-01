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

- **The macOS app.** A `.app` ships through a Homebrew **cask**, not this
  formula, and not until F22 signing is resolved.
- **Model weights.** Per F21 a formula never ships a 1.6 GB model. The default
  model is decided ([D1](DECISIONS.md)) and its checksums are now pinned
  ([D4](DECISIONS.md)). The ASR backend that consumes them is the `asr` extra
  (D5), which is Apple Silicon only and so cannot be a hard dependency of the
  formula.

## Still blocking a real product release

- **F22, signing and notarization.** The one real blocker. See below.
- **F23, model licensing.** Whisper is MIT, which is why it was chosen, but
  `LICENSES-MODELS.md` still has to exist before anything downloads weights.

Two things that stood here as blockers are done: checksum pinning under D2
([D4](DECISIONS.md)), and the capture path, which has now been exercised by a
person end to end ([macos/TESTING.md](../macos/TESTING.md)).

## F22 — what signing actually takes

There is no way around it, and the alternatives were checked rather than
assumed. Comparable projects pay: [Vorssaint](https://github.com/vorssaintapp/vorssaint-utils),
a menu bar app in the same shape and needing the same permissions, ships
Developer ID–signed and notarized builds and says so in its README.

**Ad-hoc signing is not a substitute.** `codesign --sign -` is what
`Tools/setup-testing.sh` does, and it works *only* because a locally compiled
app is never quarantined. The moment a `.dmg` is downloaded, the quarantine
attribute is set and Gatekeeper refuses it regardless of ad-hoc signature.
Telling users to run `xattr -dr com.apple.quarantine` teaches a habit that is
dangerous everywhere else, so the cask does not ship until this is real.

**It is worth more than getting past Gatekeeper.** A stable Developer ID also
means **TCC grants survive updates**. Accessibility and Microphone permissions
are keyed to the signing identity; an ad-hoc build is keyed by path and
re-prompts unpredictably across rebuilds, which is why
[macos/TESTING.md](../macos/TESTING.md) documents `tccutil reset` at all. A
signed app is granted once.

### The steps, for the day the membership exists

1. **Enrol** in the Apple Developer Program (99 USD/year).
2. **Create a Developer ID Application certificate** in the developer portal,
   download it, and add it to the login keychain. `security find-identity -v
   -p codesigning` should then list it.
3. **Create an app-specific password** for notarization at appleid.apple.com,
   and store credentials once:

   ```sh
   xcrun notarytool store-credentials cochlea-notary \
     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
   ```

4. **Sign with a hardened runtime**, which notarization requires. Note that
   `--options runtime` is not optional and that the entitlements file must
   permit nothing cochlea does not use:

   ```sh
   codesign --force --deep --options runtime --timestamp \
     --sign "Developer ID Application: Your Name (TEAMID)" build/cochlea.app
   ```

5. **Notarize and staple**, so the check works offline:

   ```sh
   hdiutil create -volname cochlea -srcfolder build/cochlea.app -ov -format UDZO cochlea.dmg
   xcrun notarytool submit cochlea.dmg --keychain-profile cochlea-notary --wait
   xcrun stapler staple cochlea.dmg
   spctl -a -vvv -t install cochlea.dmg      # must say "accepted, Developer ID"
   ```

6. **Attach the `.dmg` to the release**, then set `version`, `sha256` and the
   URL in [`Casks/cochlea.rb`](../Casks/cochlea.rb) and drop `sha256 :no_check`.

7. In CI, the certificate goes in as a base64 secret and is imported into a
   temporary keychain. Do not sign from a developer's laptop for a public
   release: the artifact should be reproducible from the tag.

### One trap, before there is a signed build

The development build and any future signed build currently share the bundle
identifier `com.cochlea.app`. Because TCC keys grants by identity, a machine
that has granted Accessibility to a locally built cochlea will behave
confusingly when a signed one arrives. Giving the dev build its own identifier
— as Vorssaint does with a separate `--dev` variant — avoids that, at the cost
of re-granting permissions once. Worth doing **before** the first signed
release, not after.
