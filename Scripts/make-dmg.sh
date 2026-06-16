#!/usr/bin/env bash
# Build a drag-to-install DMG (Lineup.app + an Applications shortcut) from an already-built
# app bundle. Run ./Scripts/build-app.sh <DIR> first, then this with the same DIR.
# Usage: ./Scripts/make-dmg.sh [OUTPUT_DIR]   (default: dist)
set -euo pipefail

OUT="${1:-dist}"
APP="$OUT/Lineup.app"
[ -d "$APP" ] || { echo "no $APP — run ./Scripts/build-app.sh \"$OUT\" first" >&2; exit 1; }

# A release DMG must not contain an ad-hoc app: its signature changes every build, so users
# would have to re-grant Accessibility on every update. The bundle's designated requirement
# is cert-based only when signed with the stable identity (see Scripts/setup-signing.sh).
# This guards even a stale/prebuilt ad-hoc bundle, regardless of how it was built. Override
# with ALLOW_ADHOC_DMG=1 for a throwaway local/test DMG.
# Capture first, then grep: piping codesign into `grep -q` lets grep exit on match while codesign
# is still writing, so codesign dies with SIGPIPE (141) and `set -o pipefail` turns that into a
# false "ad-hoc" rejection of a perfectly good Developer ID bundle.
app_req="$(codesign -d -r- "$APP" 2>&1 || true)"
if ! grep -q 'certificate leaf' <<<"$app_req"; then
  if [ "${ALLOW_ADHOC_DMG:-0}" = "1" ]; then
    echo "WARNING: packaging an AD-HOC app (ALLOW_ADHOC_DMG=1); users will re-grant Accessibility per update." >&2
  else
    echo "error: $APP is ad-hoc signed; a release DMG would force users to re-grant Accessibility on" >&2
    echo "       every update. Run ./Scripts/setup-signing.sh, rebuild, then retry — or set" >&2
    echo "       ALLOW_ADHOC_DMG=1 for a throwaway test DMG." >&2
    exit 1
  fi
fi
# `-d -r-` shows the embedded requirement but doesn't prove the bundle still verifies; since
# this script gates prebuilt bundles too, confirm the signature is actually intact.
codesign --verify --strict "$APP" || { echo "error: $APP failed signature verification; not packaging." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
DMG="$OUT/Lineup-$VERSION.dmg"
RW="$OUT/.lineup-rw.dmg"
MNT="$(mktemp -d)"

# No rm -rf: detach the mount (its dir empties), rmdir it, delete the single scratch image.
cleanup() {
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
  rm -f "$RW"
}
trap cleanup EXIT

SIZE=$(( $(du -sm "$APP" | cut -f1) + 20 ))
echo "==> creating ${SIZE}MB writable image"
hdiutil create -size "${SIZE}m" -fs HFS+ -volname "Lineup" -ov "$RW" >/dev/null

echo "==> staging app + Applications shortcut"
hdiutil attach "$RW" -nobrowse -noverify -mountpoint "$MNT" >/dev/null
ditto "$APP" "$MNT/Lineup.app"
ln -s /Applications "$MNT/Applications"
hdiutil detach "$MNT" >/dev/null

echo "==> compressing -> $DMG"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

# Sign the DMG itself with the Developer ID identity when one is present, so it can be
# notarized and Gatekeeper reports "Notarized Developer ID" for the disk image. Without a
# Developer ID cert (self-signed/ad-hoc builds), the DMG stays unsigned as before — those
# releases aren't notarized anyway.
DEVID="${DEVELOPER_ID_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -n "${DEVID}" ]; then
  echo "==> signing the DMG with Developer ID: ${DEVID}"
  codesign --force --timestamp --sign "${DEVID}" "$DMG"
fi

echo "==> done: $DMG"
echo "    Drag-install: open the DMG, drag Lineup into Applications."
if [ -n "${DEVID}" ]; then
  echo "    Next: ./Scripts/notarize.sh \"$DMG\"   (notarize + staple)"
fi
