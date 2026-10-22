<p align="center">
  <img src="docs/icon.png" width="128" alt="Simple Comic">
</p>

<h1 align="center">Simple Comic</h1>

<p align="center">
  A streamlined comic viewer for macOS.<br>
  This fork adds a paper effect and a library.
</p>

---

Simple Comic is [Dancing Tortoise Software's comic viewer](https://github.com/arauchfuss/Simple-Comic),
continued by [MaddTheSane](https://github.com/MaddTheSane/Simple-Comic). Nearly all of it is their
work, and the reading window is deliberately unchanged: the whole point of the app is to get out of
the way while you read.

This fork adds two things.

## Paper effect

Printed comics do not have pure black ink on pure white stock. The paper is warm and slightly rough,
and its fibre shows *through* uneven ink rather than sitting on top of it. The effect reproduces that:
harsh blacks are lifted, a warm tone is applied, and a paper texture is composited so that dark and
coloured areas keep their tooth. It runs as a Metal Core Image kernel, so it costs a page decode, not
a stutter.

Four parameters — show-through, grain, warmth and black lift — plus presets for **Cream paper**,
**Newsprint**, **Manga** and **E-Ink**. The settings panel previews them live on a sample page.

## Library

The library stores **covers and metadata, not your comics**. Point it at a folder and it reads each
file's first page and its `ComicInfo.xml`; the archives stay exactly where they are. When you open a
comic, its bytes are fetched into the app on demand, and you can throw that copy away again
afterwards without losing the cover, the metadata or your reading position. That keeps a large
collection on a NAS or an external disk usable without duplicating it.

- Cover grid with search, sorting and filters, and a details sidebar for series, credits and the
  story index that anthology issues carry in their summary
- Reading position written back per comic, so a comic reopens where you left it
- Opens at the last comic you were reading, next to the library window
- Keyboard navigation, and the usual double-click to open

## Live Text

Text in comics is recognised on device (Apple Silicon) and can be selected, copied, spoken, looked up
and **translated**.

- The cursor turns into an I-beam over selectable text; drag to select
- **Copy**, **Select All** and **Speak** on the **Edit** menu work
- Right-click a selection for Copy, Look Up, Translate and Speak
- ⌘-drag adds another selection rectangle
- Two-page spreads, rotation, page order and zoom all behave

## Formats

CBZ, CBR, CB7, CBT, ZIP, RAR, 7z, LHA, Tar, PDF, and folders of images.

**Quick Comic**, a bundled Quick Look plugin, gives Finder previews and thumbnails for `cbr` and
`cbz` files.

## Install

```
brew tap wiredframe/tap
brew trust --cask wiredframe/tap/simple-comic-paper
brew install --cask simple-comic-paper
```

Homebrew refuses casks from taps outside its own repositories until you say you trust them —
`brew trust` is that "yes", and it is asked once per tap, for any third-party cask.

The cask is called `simple-comic-paper` only so this line stays short: Homebrew's own repository
already has a `simple-comic`, and two of them would mean typing the fully qualified name every
time. The app is still Simple Comic and still installs to `/Applications`, so it replaces the
build from Homebrew's cask rather than sitting beside it.

Or download the `.zip` from [Releases](https://github.com/Wiredframe/Simple-Comic/releases) and move
`Simple Comic.app` into `/Applications`.

### About Gatekeeper

Builds here are signed the way any local Xcode build is, but they are not notarised by Apple.
Notarising requires a paid Apple Developer membership, and tying every release of an open-source
app to a subscription is not a trade this project wants to make. macOS therefore quarantines the
download and would refuse to open it the first time. Homebrew 6 removed the `--no-quarantine`
flag that used to sidestep this, so the cask clears the attribute itself after installing and
`brew install` just works.

**After a manual download** the flag is still there, so open the app once via right-click →
**Open**, or run:

```
xattr -dr com.apple.quarantine "/Applications/Simple Comic.app"
```

Building from source has no such prompt.

## Build from source

Requires Xcode 26 or newer and macOS 14 or later at runtime. The Metal toolchain component is needed once
for the paper effect kernel (`xcodebuild -downloadComponent MetalToolchain`).

```
git clone https://github.com/Wiredframe/Simple-Comic.git
cd Simple-Comic
git submodule update --init --recursive
xcodebuild -project SimpleComic.xcodeproj -scheme "Simple Comic" build
```

`scripts/release.sh` builds a universal Release configuration, packs it and prints the SHA-256
the Homebrew cask needs.

## Privacy

The app collects nothing. Text recognition and translation are handled by macOS on your machine.

GitHub collects data when you interact with the project here, which is outside our control.

## Licence and credits

MIT — see [`license.txt`](license.txt), which keeps the original notice.

- **Simple Comic** by Dancing Tortoise Software, continued by
  [MaddTheSane](https://github.com/MaddTheSane/Simple-Comic)
- **XADMaster** by Dag Ågren, for archive handling (LGPL 2.1). The unrar sources it contains may not
  be used to recreate the RAR compression algorithm.
- **UniversalDetector** for text encoding detection, and **WebP** support via libwebp
