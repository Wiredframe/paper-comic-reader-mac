<p align="center">
  <img src="docs/icon.png" width="128" alt="Paper Comic Reader">
</p>

<h1 align="center">Paper Comic Reader</h1>

<p align="center">
  A comic reader for the Mac that makes the page look printed.<br>
  The Mac companion of Paper Comic on iPhone and iPad.
</p>

---

One window: the library, which turns into the reader when you open a comic and back again when
you are done. More comics open as tabs. The window can fit itself to the pages, the full height of
the screen and exactly as wide as a page or a spread, so nothing but the comic is on screen.

## Paper effect

Printed comics do not have pure black ink on pure white stock. The paper is warm and slightly rough,
and its fibre shows *through* uneven ink rather than sitting on top of it. The effect reproduces that:
harsh blacks are lifted, a warm tone is applied, and a paper texture is composited so that dark and
coloured areas keep their tooth. It runs as a Metal Core Image kernel, off the main thread.

Four parameters (show-through, grain, warmth, black lift) and presets for **Cream paper**,
**Newsprint**, **Manga** and **E-Ink**, previewed live in Settings.

## Library

The library holds **covers and metadata, not your comics**. Point it at a folder and it reads each
comic's first page and its `ComicInfo.xml`; the files stay where they are. A comic is downloaded
when you open it, and the download can be removed again without losing the cover, the metadata,
your bookmarks or your place. A large collection on a NAS or an external disk stays usable without
being copied.

- Cover grid with search, filters, sort orders and a details inspector with credits and the story
  index anthology issues carry
- Bookmarks, with every bookmarked page in the library at a glance
- Comics can also be imported straight in, from the Finder or with File › Import Comics

### Moving a library between Mac, iPhone and iPad

File › Export Library writes one `.zip` with reading progress, favorites, bookmarks and the comics
you imported yourself. Paper Comic on iPhone and iPad reads the same file, and writes it too, so a
library moves either way. Comics from the library folder travel as references and are fetched from
the folder on the other device.

## Reading

- One page or two side by side, the cover alone as a printed comic opens, wide pages on their own
- Left to right or right to left (manga)
- Fit the page or the width, zoom with a pinch or ⌘+ and ⌘−, drag a zoomed page around
- Turn pages with the arrow keys, the space bar, a two-finger swipe or a click on the page's edge
- **Live Text**: text on a page can be selected, copied, looked up and translated
- Quick Look shows a comic's cover in the Finder

Formats: CBZ (and plain ZIP archives of images), like the iOS app.

## Coming from Simple Comic

Up to 2.0 this was a fork of [Simple Comic](https://github.com/MaddTheSane/Simple-Comic) with a
paper effect and a library. 3.0 is a new app built on the core of the iOS app. It keeps Simple
Comic's bundle id, so its library (folder, covers, downloads, reading positions, favorites) and the
paper settings are taken over on first launch. The old files are copied, never moved.

## Install

```
brew tap wiredframe/tap
brew trust --cask wiredframe/tap/paper-comic-reader
brew install --cask paper-comic-reader
```

Homebrew refuses casks from taps outside its own repositories until you say you trust them, and
`brew trust` is that "yes", asked once per tap.

Or download the `.zip` from [Releases](https://github.com/Wiredframe/Simple-Comic/releases) and move
`Paper Comic Reader.app` into `/Applications`.

### About Gatekeeper

Builds here are signed the way any local Xcode build is, but they are not notarised by Apple.
Notarising requires a paid Apple Developer membership, and tying every release of an open-source
app to a subscription is not a trade this project wants to make. macOS therefore quarantines the
download; the cask clears that flag after installing, so `brew install` just works.

**After a manual download** open the app once via right-click › **Open**, or run:

```
xattr -dr com.apple.quarantine "/Applications/Paper Comic Reader.app"
```

## Build from source

Requires macOS 14 or later, Xcode 26 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and, once, the Metal toolchain for the paper kernel
(`xcodebuild -downloadComponent MetalToolchain`).

```
git clone https://github.com/Wiredframe/Simple-Comic.git
cd Simple-Comic
xcodegen generate
xcodebuild -project PaperComicReader.xcodeproj -scheme "Paper Comic Reader" build
```

Debug builds use the bundle id `de.wiredframe.simplecomic.dev` and so a library of their own; only
Release builds see the real one. `xcodebuild … test` runs the unit tests, which never touch a
library at all. `scripts/release.sh` builds a universal Release configuration, packs it and prints
the SHA-256 the cask needs.

## Privacy

The app collects nothing. Text recognition and translation are handled by macOS on your Mac.

## Licence and credits

MIT, see [`license.txt`](license.txt), which keeps the original Simple Comic notice.

- **Simple Comic** by Dancing Tortoise Software, continued by
  [MaddTheSane](https://github.com/MaddTheSane/Simple-Comic), where this app began
- **ZIPFoundation** by Thomas Zoechling, for reading CBZ archives (MIT)
