# typed: strict
# frozen_string_literal: true

# Homebrew cask for this fork of Simple Comic.
#
# Belongs in a tap repository (GitHub repo `Wiredframe/homebrew-tap`, path
# `Casks/simple-comic-paper.rb`) and is kept here so it ships with the source it describes. After a
# release, update `version` and `sha256` from the output of scripts/release.sh and push the tap.
#
# The token is `simple-comic-paper` rather than `simple-comic` purely so the install line stays
# short. Homebrew's own repository already has a `simple-comic` cask, and two taps offering the
# same token force everyone to type the fully qualified `wiredframe/tap/simple-comic` forever.
# With a unique token, `brew install --cask simple-comic-paper` is enough. The app itself is
# still called Simple Comic and still installs to the same place, so `conflicts_with` keeps the
# two from landing on top of each other.
#
# The build is not notarised (see scripts/release.sh for why), so macOS quarantines the download
# and would refuse to open it on the first try. Homebrew's DSL has no stanza to opt out of that,
# and Homebrew 6 removed the user-side `--no-quarantine` flag as well, which leaves a
# `postflight_steps` block as the only way to spare people a Gatekeeper block. The caveats say
# plainly that it happened.
#
# `sha256` must match the asset that was actually published: take it from the release notes the
# workflow writes, not from a local build, since two builds of the same source do not produce
# byte-identical zips.

cask "simple-comic-paper" do
  version "2.0.3"
  sha256 "f24eb6a5f1d5f12a95f4e1bef04a8981ff729808d9b03826d5323661a4f1e622"

  url "https://github.com/Wiredframe/Simple-Comic/releases/download/v#{version}/Simple-Comic-#{version}.zip"
  name "Simple Comic"
  desc "Comic viewer with a paper effect and a library"
  homepage "https://github.com/Wiredframe/Simple-Comic"

  conflicts_with cask: "homebrew/cask/simple-comic"
  depends_on macos: :sonoma

  app "Simple Comic.app"

  postflight_steps do
    # `must_succeed: false` because the attribute is legitimately absent sometimes (a local
    # build, a re-run) and xattr treats a missing attribute as an error.
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Simple Comic.app"],
        must_succeed: false
  end

  zap trash: [
    "~/Library/Application Scripts/de.wiredframe.simplecomic",
    "~/Library/Containers/de.wiredframe.simplecomic",
    "~/Library/Containers/de.wiredframe.simplecomic.QuickComic-Preview",
    "~/Library/Containers/de.wiredframe.simplecomic.QuickComic-Thumbnailer",
    "~/Library/Saved Application State/de.wiredframe.simplecomic.savedState",
  ]

  caveats <<~EOS
    This build is signed but not notarised by Apple, so macOS quarantined the download.
    The cask has cleared that flag for you, which is what lets the app open normally.
    If you would rather macOS asked you, reinstall and run instead:
      xattr -w com.apple.quarantine "0081;00000000;;" "/Applications/Simple Comic.app"
  EOS
end
