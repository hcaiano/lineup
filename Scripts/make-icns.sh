#!/usr/bin/env bash
# Render and compile the native app icon from Design/AppIcon/Lineup.icon.
# Writes the Icon Composer previews, Resources/AppIcon.icns, Icon/icon-1024.png and the receipt.
# Usage: ./Scripts/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "error: select the native document in Design/AppIcon/manifest.json, then run ./Scripts/make-icns.sh" >&2
  exit 1
fi

swift Scripts/make-icon.swift export
echo "==> wrote Resources/AppIcon.icns from the native document"
