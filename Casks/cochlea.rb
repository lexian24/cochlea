# Homebrew cask for the cochlea macOS app.
#
# NOT USABLE YET. The app (M0) is an uncompiled Swift draft and there is no
# signed, notarized .dmg to install. This file records the shape of the cask so
# the release path is defined before the artifact exists, not improvised after.
#
# Blocked on, in order:
#   1. macos/ compiling and running at all.
#   2. F22 — an Apple Developer ID signature and notarization. Gatekeeper
#      blocks an unsigned app that requests Accessibility and Microphone, and a
#      cask that installs one is a broken install for every user.
#   3. A tagged release carrying a .dmg asset.
#
# Once those hold, `brew install --cask cochlea` works from this repository's
# tap. Acceptance into homebrew-cask (so the tap is unnecessary) additionally
# requires meeting their notability threshold.
cask "cochlea" do
  version "0.0.0"
  sha256 :no_check

  url "https://github.com/lexian24/cochlea/releases/download/v#{version}/cochlea-#{version}.dmg"
  name "cochlea"
  desc "Local-only personalized dictation that adapts to one person"
  homepage "https://github.com/lexian24/cochlea"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "cochlea.app"

  uninstall quit: "com.cochlea.app"

  # The correction store is the durable asset (SPEC §1.3) and holds a record of
  # what the user has dictated. Removing it is `zap`, never `uninstall`, so
  # `brew uninstall` cannot silently destroy it.
  zap trash: [
    "~/.cochlea",
    "~/Library/Preferences/com.cochlea.app.plist",
    "~/Library/Application Support/cochlea",
  ]

  caveats <<~EOS
    cochlea needs two permissions, and asks for each one the first time you use
    the feature that needs it — never at launch:

      Microphone      to hear what you dictate
      Accessibility   to type the result at your cursor

    It does not read the contents of other applications. Nothing leaves your
    Mac.
  EOS
end
