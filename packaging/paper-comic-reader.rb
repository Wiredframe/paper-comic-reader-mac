# typed: strict
# frozen_string_literal: true

# Homebrew cask for Paper Comic Reader on the Mac.
#
# Belongs in the tap repository (GitHub repo `Wiredframe/homebrew-tap`, path
# `Casks/paper-comic-reader.rb`) and is kept here so it ships with the source it describes. After a
# release, update `version` and `sha256` from the release notes and push the tap.
#
# It replaces the `simple-comic-paper` cask: the app was Simple Comic with a paper effect until 3.0,
# and keeps that app's bundle id, so the library and settings carry over. The tap's
# `cask_renames.json` maps the old token onto this one, so `brew upgrade` moves people across.
# No `conflicts_with` for the old token: through the rename it resolves to this cask itself, and
# Homebrew then refuses to install it ("conflicts with 'paper-comic-reader'").
#
# The build is not notarised (see scripts/release.sh for why), so macOS quarantines the download.
# Homebrew has no stanza to opt out of that, which leaves `postflight_steps` clearing the flag as
# the only way to spare people a Gatekeeper block. The caveats say plainly that it happened.
#
# `sha256` must match the asset that was actually published: take it from the release notes the
# workflow writes, not from a local build, since two builds do not produce byte-identical zips.

cask "paper-comic-reader" do
  version "3.0.3"
  sha256 "3b2feaef88199b0ea1002dae3c744eec73bd84273eedf184ef6c49942733c0e4"

  url "https://github.com/Wiredframe/paper-comic-reader-mac/releases/download/v#{version}/Paper-Comic-Reader-#{version}.zip"
  name "Paper Comic Reader"
  desc "Comic reader with a paper effect and a library"
  homepage "https://github.com/Wiredframe/paper-comic-reader-mac"

  depends_on macos: :sonoma

  app "Paper Comic Reader.app"

  postflight_steps do
    # `must_succeed: false` because the attribute is legitimately absent sometimes (a local
    # build, a re-run) and xattr treats a missing attribute as an error.
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Paper Comic Reader.app"],
        must_succeed: false
  end

  zap trash: [
    "~/Library/Application Scripts/de.wiredframe.simplecomic",
    "~/Library/Application Scripts/de.wiredframe.simplecomic.thumbnails",
    "~/Library/Containers/de.wiredframe.simplecomic",
    "~/Library/Containers/de.wiredframe.simplecomic.thumbnails",
    "~/Library/Saved Application State/de.wiredframe.simplecomic.savedState",
  ]

  caveats <<~EOS
    This build is signed but not notarised by Apple, so macOS quarantined the download.
    The cask has cleared that flag for you, which is what lets the app open normally.
  EOS
end
