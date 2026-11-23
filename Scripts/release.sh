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
# and either a notarytool keychain profile (on your Mac):
#   NOTARY_PROFILE   made with `xcrun notarytool store-credentials`
# or an App Store Connect API key (what the GitHub workflow uses):
#   NOTARY_KEY_PATH  the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID    its key ID
#   NOTARY_ISSUER_ID the issuer ID shown above the keys in App Store Connect
# SIGNING_KEYCHAIN optionally names the keychain holding the Developer ID identity.
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
    # No hardened runtime: it's only for notarization, which an ad-hoc build
    # can't have, and its library validation would refuse code signed apart
    # from the app (such as the optional Whisper engine).
    echo "▸ Archiving (Release, ad-hoc signed)…"
    xcodebuild -scheme Slate -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" archive \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO "${STAMP[@]}" -quiet
    mkdir -p "$EXPORT"
    cp -R "$ARCHIVE/Products/Applications/Slate.app" "$EXPORT/"
else
    : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        : "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID with NOTARY_KEY_PATH}"
        : "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID with NOTARY_KEY_PATH}"
        NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    else
        : "${NOTARY_PROFILE:?Set NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID}"
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    fi
    KEYCHAIN_FLAG=()
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then KEYCHAIN_FLAG=(OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $SIGNING_KEYCHAIN"); fi
    echo "▸ Archiving (Release, Developer ID)…"
    xcodebuild -scheme Slate -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" archive \
        CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" "${KEYCHAIN_FLAG[@]}" "${STAMP[@]}" -quiet
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
    xcrun notarytool submit "$OUT/Slate-notarize.zip" "${NOTARY_AUTH[@]}" --wait
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

# A build that can't start (a missing or refused library) dies within a second or two.
echo "▸ Checking it launches…"
"$APP/Contents/MacOS/Slate" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
LAUNCHED=$!
sleep 8
if kill -0 "$LAUNCHED" 2>/dev/null; then
    kill "$LAUNCHED"
    wait "$LAUNCHED" 2>/dev/null || true
    echo "✓ Launches"
else
    wait "$LAUNCHED" && status=0 || status=$?
    echo "✗ Slate quit at launch (exit $status)"
    exit 1
fi

ZIP="$OUT/Slate-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
