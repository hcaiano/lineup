#!/usr/bin/env bash
# Build Resources/AppIcon.icns from a 1024×1024 master PNG.
# Usage: ./Scripts/make-icns.sh [master.png]
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="${1:-Icon/icon-1024.png}"
[ -f "$MASTER" ] || { echo "regenerating master via make-icon.swift"; swift Scripts/make-icon.swift "$MASTER"; }

ICONSET="Icon/AppIcon.iconset"
if [ -e "$ICONSET" ]; then
  command -v trash >/dev/null 2>&1 && trash "$ICONSET" || { echo "error: $ICONSET exists, trash unavailable" >&2; exit 1; }
fi
mkdir -p "$ICONSET" Resources

# name:size pairs for the iconset (@2x = double the @1x point size)
for entry in \
  "icon_16x16:16" "icon_16x16@2x:32" \
  "icon_32x32:32" "icon_32x32@2x:64" \
  "icon_128x128:128" "icon_128x128@2x:256" \
  "icon_256x256:256" "icon_256x256@2x:512" \
  "icon_512x512:512" "icon_512x512@2x:1024"; do
  name="${entry%%:*}"; size="${entry##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "==> wrote Resources/AppIcon.icns"
