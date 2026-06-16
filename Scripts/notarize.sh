#!/usr/bin/env bash
# Notarize and staple a Developer ID-signed artifact (.app or .dmg), so macOS opens it with
# no "unidentified developer" / "Open Anyway" prompt.
#
# Requires:
#   - the artifact signed with a Developer ID Application identity (Scripts/build-app.sh does
#     this automatically when such an identity is in the keychain), with the hardened runtime
#     and a secure timestamp;
#   - a stored notarytool credential profile (created once, keeps secrets out of scripts):
#       xcrun notarytool store-credentials "lineup-notary" \
#         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: ./Scripts/notarize.sh <path-to-.app-or-.dmg> [keychain-profile]
#        (profile defaults to $NOTARY_PROFILE or "lineup-notary")
set -euo pipefail

TARGET="${1:?usage: notarize.sh <app-or-dmg> [keychain-profile]}"
PROFILE="${2:-${NOTARY_PROFILE:-lineup-notary}}"
[ -e "$TARGET" ] || { echo "no such file: $TARGET" >&2; exit 1; }

# Refuse to "notarize" something that isn't Developer ID-signed — the submission would just be
# rejected by Apple, slowly. Catch it locally first.
if ! codesign -d -r- "$TARGET" 2>&1 | grep -q 'certificate leaf'; then
  echo "error: $TARGET is not signed with a usable certificate (ad-hoc?). Sign with Developer ID first." >&2
  exit 1
fi

# notarytool takes a single .dmg/.zip/.pkg. An .app is zipped for submission; the staple still
# attaches to the .app itself.
SUBMIT="$TARGET"
CLEANUP_ZIP=""
case "$TARGET" in
  *.app)
    SUBMIT="$(dirname "$TARGET")/$(basename "$TARGET" .app)-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    CLEANUP_ZIP="$SUBMIT"
    ;;
esac
cleanup() { [ -n "$CLEANUP_ZIP" ] && rm -f "$CLEANUP_ZIP"; }
trap cleanup EXIT

echo "==> submitting to Apple's notary service (typically 1-5 min)"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait

echo "==> stapling the notarization ticket to $TARGET"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Prove Gatekeeper will accept it (the check users' Macs do on first open).
case "$TARGET" in
  *.app) spctl -a -vvv -t exec "$TARGET" ;;
  *.dmg) spctl -a -vvv -t open --context context:primary-signature "$TARGET" ;;
esac

echo "==> done: $TARGET is notarized + stapled."
