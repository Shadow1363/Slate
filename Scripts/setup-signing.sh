#!/bin/bash
# One-time setup for Developer ID signing and notarization, on this Mac and
# in the GitHub release workflow. Run it yourself: it asks for files and
# passwords and never prints a secret.
#
# Before you start (both in your Apple Developer account):
#   1. A "Developer ID Application" certificate in your login keychain:
#      Xcode › Settings › Accounts › your team › Manage Certificates › + ›
#      Developer ID Application. (Only the account holder can make one.)
#      Then Keychain Access › My Certificates › right-click
#      "Developer ID Application: …" › Export… › save as a .p12 with a password.
#   2. An App Store Connect API key for notarizing:
#      appstoreconnect.apple.com › Users and Access › Integrations ›
#      App Store Connect API › Team Keys › + (access: Developer).
#      Download the AuthKey_XXXXXXXXXX.p8 (you only get one chance) and note
#      the Key ID and the Issuer ID shown above the list.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-Shadow1363/Slate}"

identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [[ -z "$identity" ]]; then
    echo "✗ No \"Developer ID Application\" certificate in your keychain yet."
    echo "  Make one in Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application, then run this again."
    exit 1
fi
TEAM_ID=$(echo "$identity" | sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/')
echo "✓ Found $(echo "$identity" | sed -E 's/^[^"]*"([^"]*)".*/\1/')"

read -r -p "Path to the exported Developer ID .p12: " P12
P12="${P12/#\~/$HOME}"
[[ -f "$P12" ]] || { echo "✗ $P12 not found"; exit 1; }
read -r -s -p "The .p12's password: " P12_PASSWORD; echo
read -r -p "Path to AuthKey_….p8: " KEY
KEY="${KEY/#\~/$HOME}"
[[ -f "$KEY" ]] || { echo "✗ $KEY not found"; exit 1; }
read -r -p "Key ID: " KEY_ID
read -r -p "Issuer ID: " ISSUER_ID

echo "▸ Saving the notarization profile \"slate-notary\" in your keychain (for Scripts/release.sh here)…"
xcrun notarytool store-credentials slate-notary --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER_ID" >/dev/null
echo "▸ Checking Apple accepts the key…"
xcrun notarytool history --keychain-profile slate-notary >/dev/null && echo "✓ Notary credentials work"

echo "▸ Storing GitHub secrets on $REPO…"
base64 -i "$P12" | gh secret set DEVELOPER_ID_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO"
base64 -i "$KEY" | gh secret set NOTARY_KEY --repo "$REPO"
printf '%s' "$KEY_ID" | gh secret set NOTARY_KEY_ID --repo "$REPO"
printf '%s' "$ISSUER_ID" | gh secret set NOTARY_ISSUER_ID --repo "$REPO"
printf '%s' "$TEAM_ID" | gh secret set APPLE_TEAM_ID --repo "$REPO"
echo "✓ Done. Signed builds here:  TEAM_ID=$TEAM_ID NOTARY_PROFILE=slate-notary Scripts/release.sh"
echo "  The next push to main publishes a signed, notarized release."
echo "  Keep the .p12 and .p8 somewhere safe (not in this repo)."
