#!/bin/bash
#
# Archives Paper Comic Reader for the Mac App Store and exports an uploadable .pkg.
#
# The Mac app shares the iOS app's bundle id (de.wiredframe.comicreader), so it ships as the macOS
# platform of the same App Store record: a Universal Purchase, one listing for iPhone, iPad and
# Mac. Upload the .pkg there, to the macOS version, not to a new app.
#
# Differences from scripts/release.sh (GitHub and Homebrew, ad-hoc signed):
#   * signed by the team with automatic signing, so Xcode fetches the Mac App Store profiles;
#   * the result is an .xcarchive plus a .pkg, not a zip.
# Entitlements are the same in both: sandbox, user-selected files, app-scoped bookmarks.
#
# `-exportArchive` needs an Apple account signed in to Xcode (cloud signing). The App Store
# Connect API key alone is not enough and fails with "Cloud signing permission error".
#
# Upload, either way:
#   Xcode › Window › Organizer › the archive › Distribute App › App Store Connect
#   xcrun altool --upload-app -f build/appstore/export/*.pkg -t macos \
#     --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
#
# Usage: scripts/release-appstore.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="PaperComicReader.xcodeproj"
SCHEME="Paper Comic Reader"
OUT="build/appstore"
ARCHIVE="$OUT/Paper Comic Reader.xcarchive"
EXPORT="$OUT/export"
TEAM="7RN999S858"

xcodegen generate --quiet

echo "* 1/3  Tests"
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' -quiet

echo "* 2/3  Archive"
rm -rf "$OUT"
mkdir -p "$OUT"
# DEPLOYMENT_POSTPROCESSING strips the binaries, as in release.sh.
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-destination 'generic/platform=macOS' \
	-archivePath "$ARCHIVE" \
	DEVELOPMENT_TEAM="$TEAM" \
	CODE_SIGN_STYLE=Automatic \
	CODE_SIGN_IDENTITY="Apple Development" \
	DEPLOYMENT_POSTPROCESSING=YES \
	-allowProvisioningUpdates

# SwiftPM resource bundles (ZIPFoundation's privacy manifest) come out of the archive signed with
# the development certificate, and the export does not re-sign them, which App Store Connect
# rejects (ITMS-90284). They hold no code, so they go in unsigned: the app's own signature seals
# their files, and the export re-signs the app and its extension.
find "$ARCHIVE/Products/Applications" -name "*.bundle" -path "*/Resources/*" -prune -print | while read -r bundle; do
	rm -rf "$bundle/Contents/_CodeSignature" "$bundle/_CodeSignature"
done

echo "* 3/3  Export for App Store Connect"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$EXPORT" \
	-exportOptionsPlist "$OUT/ExportOptions.plist" \
	-allowProvisioningUpdates

echo
echo "Archive : $ARCHIVE"
echo "Export  : $EXPORT"
/bin/ls "$EXPORT"/*.pkg
