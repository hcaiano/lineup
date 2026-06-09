#!/usr/bin/env bash
# Build a drag-to-install DMG (Lineup.app + an Applications shortcut) from an already-built
# app bundle. Run ./Scripts/build-app.sh <DIR> first, then this with the same DIR.
# Usage: ./Scripts/make-dmg.sh [OUTPUT_DIR]   (default: dist)
set -euo pipefail

OUT="${1:-dist}"
APP="$OUT/Lineup.app"
[ -d "$APP" ] || { echo "no $APP — run ./Scripts/build-app.sh \"$OUT\" first" >&2; exit 1; }

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

echo "==> done: $DMG"
echo "    Drag-install: open the DMG, drag Lineup into Applications."
