# Homebrew formula for the cochlea CLI.
#
# STATUS: not yet publishable. `url` and `sha256` below point at a release tag
# that does not exist. Nothing installs from this formula until a tag is cut
# and `scripts/stamp-formula.sh` fills those two fields in. See
# docs/RELEASING.md.
#
# This formula installs the `dictate` CLI only. The macOS menu bar app and the
# dictation capture path land at M0 and are not part of this package. Per SPEC
# F21 a formula never ships model weights: models are downloaded on first run
# with checksum verification.
class Cochlea < Formula
  include Language::Python::Virtualenv

  desc "Local-only personalized dictation that adapts to one person"
  homepage "https://github.com/lexian24/cochlea"
  url "https://github.com/lexian24/cochlea/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/lexian24/cochlea.git", branch: "main"

  depends_on "python@3.12"

  def install
    virtualenv_install_with_resources
  end

  def caveats
    <<~EOS
      This package installs the `dictate` CLI only.

      The dictation capture path (hotkey, VAD, on-device ASR, type-at-cursor)
      is milestone M0 and is not implemented yet, so `dictate` cannot transcribe
      audio. What works today: importing text to seed the lexicon, the
      correction store, and the attribution filter.

        dictate doctor      show versions and what is wired up
        dictate import      seed the lexicon from your own git history
        dictate stats       correction-store metrics

      Mandarin support is optional and not installed by default:
        pip install 'cochlea[zh]'

      Nothing leaves this machine. There is no cloud component.
    EOS
  end

  test do
    assert_match "cochlea #{version}", shell_output("#{bin}/dictate --version")
    # `doctor` must run against a machine with no store and no models, since
    # that is every machine immediately after installation.
    output = shell_output("#{bin}/dictate doctor")
    assert_match "schema version", output
    assert_match "phonetic backends", output

    # A fresh install must default to text-only: acoustic retention is opt-in
    # (SPEC invariant 7) and this is the check that would catch a regression
    # flipping that default.
    stats = shell_output("#{bin}/dictate --store #{testpath}/t.db stats")
    assert_match "text-only", stats

    # Unimplemented subcommands must report their milestone, not crash.
    assert_match "not implemented",
                 shell_output("#{bin}/dictate train 2>&1", 2)
  end
end
