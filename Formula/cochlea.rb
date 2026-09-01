# Homebrew formula for the cochlea CLI.
#
# This formula installs the `dictate` CLI only. The menu bar app is a separate
# artifact and is not packaged yet: it needs a Developer ID signature and
# notarization first (SPEC F22), and a cask that installs an unsigned app that
# asks for Accessibility is a broken install for every user. Build it from
# source in the meantime -- see macos/BUILDING.md.
#
# Per SPEC F21 a formula never ships model weights: they are downloaded on
# first run and verified against a pinned SHA-256 (D4).
class Cochlea < Formula
  include Language::Python::Virtualenv

  desc "Local-only personalized dictation that adapts to one person"
  homepage "https://github.com/lexian24/cochlea"
  # Both fields are written by scripts/stamp-formula.sh, which fetches the
  # published tarball and takes its checksum -- a formula cannot be published
  # with a placeholder hash, and the hash cannot be known until the tag exists.
  url "https://github.com/lexian24/cochlea/archive/refs/tags/v0.2.0.tar.gz"
  version "0.2.0"
  sha256 "8773595c36233544151b8a913ca90ae7b5505b456c3d4c768f8893ae147d56ef"
  license "MIT"
  head "https://github.com/lexian24/cochlea.git", branch: "main"

  depends_on "python@3.12"

  def install
    virtualenv_install_with_resources
  end

  def caveats
    <<~EOS
      This installs the `dictate` CLI. The menu bar app is not packaged yet
      (it needs signing first) -- build it from source:
        https://github.com/lexian24/cochlea/blob/main/macos/BUILDING.md

      Speech recognition needs one more package, and it is Apple Silicon only
      because MLX has no wheel for anything else:

        pip install 'cochlea[asr]'
        dictate asr-check sample.wav --model ~/.cochlea/models/whisper-small

      What works without it:

        dictate doctor      versions, and what is wired up
        dictate import      seed the lexicon from your own writing or git log
        dictate lexicon     what dictation is biased towards
        dictate correct     record a correction
        dictate review      corrections the filter could not classify
        dictate stats       correction-store metrics

      Mandarin support is optional:
        pip install 'cochlea[zh]'

      Nothing leaves this machine, and there is no service that could receive
      it. What is stored, and how to check:
        https://github.com/lexian24/cochlea/blob/main/docs/PRIVACY.md
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

    # ASR is an optional extra, so a formula-only install must say why it
    # cannot transcribe rather than failing with an import error.
    assert_match "mlx-whisper", shell_output("#{bin}/dictate doctor")

    # An import must refuse to write without --commit. This is the guard that
    # keeps text lifted from someone's private messages from being kept before
    # they have seen it.
    (testpath/"notes.txt").write("kubectl apply to the nginx cluster\n" * 3)
    proposal = shell_output("#{bin}/dictate import text #{testpath}/notes.txt")
    assert_match "Nothing was written", proposal
  end
end
