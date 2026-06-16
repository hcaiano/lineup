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

# Refuse anything that isn't DEVELOPER ID-signed. A self-signed cert also has a "certificate
# leaf" requirement (it's stable for Accessibility), but Apple only notarizes Developer ID
# software, so checking the leaf is not enough — require the Developer ID authority itself, or
# the submission fails slowly inside notarytool.
if ! codesign -dvvv "$TARGET" 2>&1 | grep -q 'Authority=Developer ID Application'; then
  echo "error: $TARGET is not signed by a Developer ID Application identity; Apple won't" >&2
  echo "       notarize it. Build with a Developer ID cert (REQUIRE_DEVELOPER_ID_SIGNATURE=1)." >&2
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
# --timeout bounds the wait so a stuck submission can't hang a release shell forever. On
# failure, surface the detailed log so the rejection reason is actionable.
if ! xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --timeout 30m; then
  echo "error: notarization failed. Fetch the reason with:" >&2
  echo "       xcrun notarytool history --keychain-profile \"$PROFILE\"" >&2
  echo "       xcrun notarytool log <submission-id> --keychain-profile \"$PROFILE\"" >&2
  exit 1
fi

echo "==> stapling the notarization ticket to $TARGET"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Prove the system will accept it (the check users' Macs do on first open). syspolicy_check is
# Apple's current tool for app distribution assessment on macOS 14+; fall back to spctl.
case "$TARGET" in
  *.app)
    if command -v syspolicy_check >/dev/null 2>&1; then
      syspolicy_check distribution "$TARGET"
    else
      spctl -a -vvv -t exec "$TARGET"
    fi
    ;;
  *.dmg) spctl -a -vvv -t open --context context:primary-signature "$TARGET" ;;
esac

echo "==> done: $TARGET is notarized + stapled."
