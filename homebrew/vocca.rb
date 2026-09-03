# Homebrew cask for Vocca. This file is the source of truth; the published tap is a
# separate repo, haqaliz/homebrew-vocca, where it goes as Casks/vocca.rb. After a release
# builds the DMG, copy the sha256 out of SHA256SUMS.txt, bump the version, and commit it
# to the tap.
#
#   brew install --cask haqaliz/vocca/vocca
#   xattr -dr com.apple.quarantine /Applications/Vocca.app   # BEFORE first launch
#   open /Applications/Vocca.app
#
# DO NOT PUBLISH THIS TO THE TAP YET. `sha256` below is a placeholder: the first DMG
# release has not been cut. v0.1.0 shipped a `zip -r` archive that flattened
# whisper.framework's symlinks, so its bundle fails `codesign --verify` and there is
# nothing installable to point at. Fill the sha256 line from the SHA256SUMS.txt of the first
# release built by the DMG packaging step, then push to the tap — not before.
#
# Vocca is signed with an Apple Development certificate, which Gatekeeper rejects for
# downloaded apps, so the quarantine flag has to come off by hand. Two things about that,
# both taken from the same measurements deck recorded on Homebrew 6.0.19 / macOS 15:
#
#   * `--no-quarantine` no longer exists. Homebrew removed the flag; passing it now fails
#     with "Error: invalid option". Older docs telling users to pass it are giving them a
#     command that cannot run.
#   * The order matters, and getting it wrong is destructive. Launching the app while it
#     is still quarantined does not merely warn — Gatekeeper *removes*
#     /Applications/Vocca.app, and not to the Trash. Strip the attribute first and the
#     same bits launch fine.
#
# All of this goes away the day notarization lands. See
# docs/planning/notarization/runbook.md step 6 for everything to delete then.
cask "vocca" do
  version "0.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/haqaliz/vocca/releases/download/v#{version}/Vocca-v#{version}.dmg"
  name "Vocca"
  desc "Local-first voice dictation that types into any macOS app"
  homepage "https://github.com/haqaliz/vocca"

  # macOS 15 is the deployment target (Package.swift `platforms: [.macOS(.v15)]` and
  # MACOSX_DEPLOYMENT_TARGET = 15.0 across every target). A bare symbol is the minimum and
  # the only form Homebrew still accepts; the `">= :sequoia"` string form warns.
  depends_on macos: :sequoia

  # Apple Silicon only, and this line is load-bearing rather than aspirational: the release
  # is built `ARCHS=arm64`, and the default ASR engine is Parakeet on CoreML/ANE. There is
  # no Intel slice to fall back to, so an Intel Mac must fail at `brew install` with a
  # legible message rather than at launch with none — Vocca is LSUIElement, and a launch
  # failure there is completely silent.
  depends_on arch: :arm64

  app "Vocca.app"

  uninstall quit: "dev.vocca.Vocca"

  # `zap` erases everything Vocca writes. Worth knowing what is in here before running it:
  # the models directory holds the downloaded ASR weights (~470 MB for Parakeet alone), so
  # a zap means the next install re-downloads them.
  #
  # `recovery/` is the failsafe journal — the on-disk half of "a transcript is never lost".
  # It is purged when a transcript is resolved, so it is normally empty, but if Vocca was
  # quit with a transcript still held, zapping discards it. That is the correct behaviour
  # for an explicit zap and the wrong thing to do casually.
  #
  # Not listed, because a cask cannot and should not: the BYOK API key, which lives in the
  # login Keychain. Delete it in Keychain Access if a BYOK cleanup provider was ever
  # configured. Silently deleting a user's Keychain item from an uninstall script is not
  # something this cask will do.
  zap trash: [
    "~/Library/Application Support/Vocca",
    "~/Library/Preferences/dev.vocca.Vocca.plist",
    "~/Library/Saved Application State/dev.vocca.Vocca.savedState",
  ]

  caveats <<~CAVEATS
    Clear the quarantine flag BEFORE opening Vocca the first time:

      xattr -dr com.apple.quarantine /Applications/Vocca.app
      open /Applications/Vocca.app

    Vocca is not notarized yet. Opening a quarantined app does not warn — macOS deletes
    it. If that has already happened, reinstall and run the line above first.

    Vocca has no Dock icon and no window at launch (it is a menu bar app). It will ask for
    Microphone and Accessibility permission — it cannot type into other apps without
    Accessibility — and downloads its speech model (~470 MB) on first run.
  CAVEATS
end
