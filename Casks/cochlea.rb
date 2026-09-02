# Homebrew cask for the cochlea macOS app.
#
# NOT USABLE YET, for one remaining reason. This file records the shape of the
# cask so the release path is defined before the artifact exists rather than
# improvised after.
#
#   1. [done] macos/ compiles, runs, and has been hand-tested end to end --
#      hotkey, microphone, transcription, typing at the cursor, streaming,
#      corrections. See macos/TESTING.md.
#   2. [NOT PLANNED] F22 -- an Apple Developer ID signature and notarization.
#      Gatekeeper blocks an unsigned app, and it is strictest with exactly the
#      permissions this one needs: Accessibility and Microphone. A cask that
#      installs an unsigned app is a broken install for every user who did not
#      compile it themselves, and telling people to run `xattr -dr
#      com.apple.quarantine` on a downloaded binary teaches a habit that is
#      dangerous everywhere else.
#      This needs an Apple Developer Program membership at 99 USD/year, and
#      that recurring cost has been decided against. It is a purchase, not a
#      patch, so no amount of work here changes it.
#   3. [blocked on 2] A tagged release carrying a signed, notarized .dmg.
#
# So there is no cask, and this file is a record rather than a plan. Building
# from source is the distribution model, and it works: a locally compiled app
# is never quarantined, so Gatekeeper does not block it.
#   https://github.com/lexian24/cochlea/blob/main/macos/BUILDING.md
#
# Kept, rather than deleted, because the shape is right and the decision could
# be revisited -- docs/RELEASING.md carries the steps. If it ever is, note that
# Homebrew 6 also requires `brew trust` for a cask from a third-party tap, and
# that acceptance into homebrew-cask proper needs their notability threshold.
cask "cochlea" do
  version "0.0.0"
  sha256 :no_check

  url "https://github.com/lexian24/cochlea/releases/download/v#{version}/cochlea-#{version}.dmg"
  name "cochlea"
  desc "Local-only personalized dictation that adapts to one person"
  homepage "https://github.com/lexian24/cochlea"

  # Symbol form, not ">= :sonoma": the string comparison is deprecated and
  # warns on every brew command that touches this tap. Sonoma is 14.0, which
  # is what the app's Info.plist asks for.
  depends_on macos: :sonoma
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
    the feature that needs it -- never at launch:

      Microphone      to hear what you dictate
      Accessibility   to type the result at your cursor

    The Accessibility permission is used to type, never to read. cochlea does
    not monitor text fields and does not watch your keyboard: the shortcut is
    registered with the system rather than tapped from the event stream.

    Nothing leaves your Mac, and there is no service that could receive it.
    What is stored, and how to check:
      https://github.com/lexian24/cochlea/blob/main/docs/PRIVACY.md
  EOS
end
