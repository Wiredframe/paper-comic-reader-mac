#!/bin/bash
#
# Builds a universal Release build of Simple Comic and packs it for a GitHub release.
#
# The build is ad-hoc signed, which is what an Xcode build without a Developer ID produces and
# what Apple Silicon needs at minimum in order to run an app at all. It is deliberately NOT
# signed with a Developer ID and NOT notarised: that would tie every future release to a paid
# membership, and this project would rather not depend on one. The cost is a Gatekeeper prompt
# on first launch, which the README and the release notes explain.
#
# If that ever changes, the way back is small: add
#   CODE_SIGN_IDENTITY="Developer ID Application: … (TEAM)" CODE_SIGN_STYLE=Manual \
#   DEVELOPMENT_TEAM=TEAM ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp"
# to the xcodebuild call below, then `xcrun notarytool submit --wait` the zip and
# `xcrun stapler staple` the app before packaging it.
#
# The zip is made with ditto rather than `zip`: it keeps symlinks, resource forks and the code
# signature intact. A plain `zip` produces an archive whose app fails signature validation on
# the other side.
#
# Usage: scripts/release.sh [output-directory]
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SimpleComic.xcodeproj"
SCHEME="Simple Comic"
APP_NAME="Simple Comic"
OUT_DIR="${1:-build/release}"
DERIVED="build/release-dd"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
if [ -z "$VERSION" ]; then
	echo "Could not read MARKETING_VERSION from the project." >&2
	exit 1
fi

echo "Building $APP_NAME $VERSION …"
rm -rf "$DERIVED"

# `generic/platform=macOS` is what makes this universal. Without a destination xcodebuild
# builds for the machine it is running on, so a release cut on Apple Silicon would ship an
# arm64-only app and leave Intel Macs with nothing, even though ARCHS lists both.
#
# MACOSX_DEPLOYMENT_TARGET on the command line reaches the vendored submodule projects too,
# which still say 10.13; Xcode 27 refuses anything below 12.0.
# DEPLOYMENT_POSTPROCESSING strips the release binaries, which `build` otherwise leaves with
# their full symbol tables (about 4.6 MB of the download).
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-destination 'generic/platform=macOS' \
	-derivedDataPath "$DERIVED" \
	MACOSX_DEPLOYMENT_TARGET=14.0 DEPLOYMENT_POSTPROCESSING=YES \
	build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP" ]; then
	echo "Build finished but $APP is missing." >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/Simple-Comic-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
ARCHES=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo "unknown")
SIGNATURE=$(codesign -dv "$APP" 2>&1 | awk -F= '/Signature/{print $2}')

echo
echo "Archive   : $ARCHIVE"
echo "Version   : $VERSION"
echo "Arches    : $ARCHES"
echo "Signature : ${SIGNATURE:-unknown}"
echo "SHA-256   : $SHA"
echo
echo "Not notarised by design. The Homebrew cask clears the quarantine flag itself;"
echo "a manual download needs right-click → Open once, or:"
echo "  xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
echo
echo "For the cask, set:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
