#!/bin/bash
# Publishes the optional Whisper engine that Settings › Voice downloads:
# Vendor/whisper.xcframework's macOS framework, zipped with whisper.cpp's
# license, as the asset of a `whisper-<version>` prerelease on GitHub.
#
#   Scripts/publish-whisper.sh           package it; prints the SHA-256 and size
#   Scripts/publish-whisper.sh --upload  upload that same zip as release whisper-<version>
#
# Put the printed SHA-256 and size in WhisperEngine.swift before uploading:
# --upload refuses a zip whose checksum isn't the one Slate expects. A new
# framework needs a new version (bump WhisperEngine.version).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/.*static let version = ([0-9]+).*/\1/p' Packages/SlateVoice/Sources/SlateVoice/WhisperEngine.swift)
REPO="${REPO:-Shadow1363/Slate}"
FRAMEWORK="Packages/SlateVoice/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
OUT="build/whisper"
ZIP="$OUT/whisper-framework-$VERSION.zip"

ENGINE="Packages/SlateVoice/Sources/SlateVoice/WhisperEngine.swift"
EXPECTED=$(sed -nE 's/.*static let sha256 = "([0-9a-f]+)".*/\1/p' "$ENGINE")

if [[ "${1:-}" == "--upload" ]]; then
    [[ -f "$ZIP" ]] || { echo "✗ $ZIP not found: run without --upload first"; exit 1; }
    SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
    [[ "$SHA" == "$EXPECTED" ]] || { echo "✗ $ZIP is $SHA but WhisperEngine.swift expects $EXPECTED"; exit 1; }
    gh release create "whisper-$VERSION" "$ZIP" --repo "$REPO" --prerelease --target main \
        --title "Whisper engine $VERSION (optional download)" \
        --notes "The optional Whisper engine for Slate (whisper.cpp, MIT). Slate downloads it from Settings › Voice when you choose Whisper; you don't need to download this by hand. SHA-256: \`$SHA\`"
    echo "✓ Published whisper-$VERSION"
    exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT/stage"
ditto "$FRAMEWORK" "$OUT/stage/whisper.framework"
# Developer ID builds of Slate keep library validation on, so they only load an
# engine signed by the same team: set SIGNING_IDENTITY ("Developer ID
# Application: …") once those builds exist, and publish a new version.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$OUT/stage/whisper.framework"
fi
sed -n '/^## whisper.cpp/,/^## Yams/p' THIRD_PARTY_NOTICES.md | sed '1d;$d' | sed '/^```$/d' > "$OUT/stage/LICENSE-whisper.cpp.txt"
(cd "$OUT/stage" && ditto -c -k --norsrc . "../$(basename "$ZIP")")

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(du -k "$ZIP" | awk '{printf "%.0f MB", $1/1024}')
echo "version: $VERSION"
echo "sha256:  $SHA"
echo "size:    $SIZE"
[[ "$SHA" == "$EXPECTED" ]] || echo "→ Put this SHA-256 in $ENGINE, then run with --upload."
