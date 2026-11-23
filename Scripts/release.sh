#!/bin/bash
# Builds Slate for distribution outside the Mac App Store.
#
#   Scripts/release.sh --adhoc     Release build, ad-hoc signed, zipped (no Apple account needed)
#   Scripts/release.sh             Developer ID signed, notarized, stapled, zipped
#
# The version comes from the VERSION file (0.9.0). Set these to override:
#   SLATE_VERSION    what the zip and About box say, e.g. 0.9.0-beta.12
#   SLATE_BUILD      the build number (CFBundleVersion), e.g. 12
#
# For the full run, set these first (see README › Distribution):
#   TEAM_ID          your 10-character Apple Developer team ID
#   NOTARY_PROFILE   a keychain profile made with `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-developer-id}"
OUT="build/release"
ARCHIVE="$OUT/Slate.xcarchive"
EXPORT="$OUT/export"
MARKETING=$(tr -d '[:space:]' < VERSION)
VERSION="${SLATE_VERSION:-$MARKETING}"
BUILD="${SLATE_BUILD:-1}"
STAMP=(MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD")

rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet

if [[ "$MODE" == "--adhoc" ]]; then
    echo "▸ Archiving (Release, ad-hoc signed)…"
    xcodebuild -scheme Slate -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" archive \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= "${STAMP[@]}" -quiet
    mkdir -p "$EXPORT"
    cp -R "$ARCHIVE/Products/Applications/Slate.app" "$EXPORT/"
else
    : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
    echo "▸ Archiving (Release, Developer ID)…"
    xcodebuild -scheme Slate -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" archive \
        CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" "${STAMP[@]}" -quiet
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
    echo "▸ Exporting…"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" -quiet
    echo "▸ Notarizing (this can take a few minutes)…"
    ditto -c -k --keepParent "$EXPORT/Slate.app" "$OUT/Slate-notarize.zip"
    xcrun notarytool submit "$OUT/Slate-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$EXPORT/Slate.app"
    rm "$OUT/Slate-notarize.zip"
fi

APP="$EXPORT/Slate.app"
echo "▸ Checking the signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|flags|TeamIdentifier" || true
if [[ "$MODE" != "--adhoc" ]]; then
    spctl -a -t exec -vv "$APP"
fi

ZIP="$OUT/Slate-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
