#!/bin/bash
# Takes the README screenshots: builds a Debug copy of Slate under its own
# bundle ID (so it never touches your Slate or its settings), runs its
# screenshot tour on a fresh Tidewater copy, and captures each step's window.
#
#   Scripts/screenshots.sh            writes docs/screenshots/*.png
#
# Needs Screen Recording permission for your terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/screenshots"
WORK="build/screenshots"
rm -rf "$WORK/steps"
mkdir -p "$OUT" "$WORK/steps"
xcodegen generate --quiet
echo "▸ Building…"
xcodebuild -project Slate.xcodeproj -scheme Slate -configuration Debug -derivedDataPath "$WORK/dd" \
    PRODUCT_BUNDLE_IDENTIFIER=app.slate.mac.screenshots -quiet build 2>&1 | grep -v "WARNING: Using the first\|platform:macOS" || true
APP="$WORK/dd/Build/Products/Debug/Slate.app"

echo "▸ Running the tour…"
# `open` launches it as a normal app (a bare binary never shows its windows).
# No restored windows from a previous run: the tour starts from the Home window.
rm -rf "$HOME/Library/Saved Application State/app.slate.mac.screenshots.savedState"
open -n --env SLATE_SCREENSHOTS="$PWD/$WORK/steps" "$APP" --args -ApplePersistenceIgnoreState YES
sleep 1
PID=$(pgrep -f "$WORK/dd/Build/Products/Debug/Slate.app/Contents/MacOS/Slate" | head -1)
LOG="$WORK/steps/steps.log"
seen=0
for _ in $(seq 1 600); do
    if [[ -f "$LOG" ]]; then
        lines=$(wc -l < "$LOG" | tr -d ' ')
        while (( seen < lines )); do
            seen=$((seen + 1))
            line=$(sed -n "${seen}p" "$LOG")
            name=${line%% *}
            case "$name" in
                progress) continue ;;
                finished) echo "✓ done"; wait "$PID" 2>/dev/null || true; exit 0 ;;
                error) echo "✗ $line"; kill "$PID" 2>/dev/null || true; exit 1 ;;
            esac
            window=${line##* }
            screencapture -x -o -l "$window" "$OUT/$name.png"
            sips -Z 1600 "$OUT/$name.png" >/dev/null
            echo "  $name.png"
            touch "$WORK/steps/$name.done"
        done
    fi
    sleep 0.3
done
echo "✗ timed out"
kill "$PID" 2>/dev/null || true
exit 1
