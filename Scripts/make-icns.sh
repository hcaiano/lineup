#!/usr/bin/env bash
# Build Resources/AppIcon.icns from the selected enamel master.
# Usage: ./Scripts/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "error: select the master in Design/AppIcon/manifest.json, then run ./Scripts/make-icns.sh" >&2
  exit 1
fi

ICONSET="Icon/AppIcon.iconset"
if [ -e "$ICONSET" ]; then
  command -v trash >/dev/null 2>&1 && trash "$ICONSET" || { echo "error: $ICONSET exists, trash unavailable" >&2; exit 1; }
fi
swift Scripts/make-icon.swift export
mkdir -p Resources

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "==> wrote Resources/AppIcon.icns"
