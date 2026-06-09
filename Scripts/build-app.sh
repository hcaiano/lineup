#!/usr/bin/env bash
# Assemble Lineup.app from the SwiftPM release binary.
#
# Why a bundle (not the raw binary): macOS Accessibility (TCC) trust is keyed to the
# app's identity + path + code signature. Always run the BUNDLED app from a stable
# location so the granted permission sticks.
#
# Signing: if a stable self-signed identity exists (see Scripts/setup-signing.sh) we sign
# with it, so the code signature is stable across rebuilds and you grant Accessibility
# only ONCE. Otherwise we fall back to ad-hoc, whose hash changes every rebuild (so you'd
# have to remove + re-grant in System Settings each time).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Lineup"
EXEC_NAME="lineup"
BUNDLE_ID="gg.gam3s.lineup"
SIGN_IDENTITY="Lineup Self-Signed"
BUILD_DIR=".build/release"
OUT_DIR="${1:-dist}"          # pass a target dir, e.g. ~/Applications
APP="${OUT_DIR}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

# Ensure the icon exists.
if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "==> building app icon"
  ./Scripts/make-icns.sh
fi

echo "==> assembling ${APP}"
if [ -e "${APP}" ]; then
  if command -v trash >/dev/null 2>&1; then
    trash "${APP}"
  else
    echo "error: '${APP}' exists and 'trash' is not installed." >&2
    echo "       Install it (brew install trash) or remove the bundle manually." >&2
    exit 1
  fi
fi
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BUILD_DIR}/${EXEC_NAME}" "${APP}/Contents/MacOS/${EXEC_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# Prefer a stable self-signed identity; fall back to ad-hoc.
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
  echo "==> codesign with stable identity '${SIGN_IDENTITY}'"
  codesign --force --options runtime --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}"
  echo "    (Accessibility permission will persist across rebuilds.)"
else
  echo "==> ad-hoc codesign (identifier: ${BUNDLE_ID})"
  codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
  echo "    NOTE: ad-hoc signature changes each rebuild -> you'll re-grant Accessibility."
  echo "    Run ./Scripts/setup-signing.sh once to make the permission stick."
fi

echo "==> done: ${APP}"
echo "    Launch with:  open \"${APP}\""
echo "    First launch will prompt for Accessibility permission."
