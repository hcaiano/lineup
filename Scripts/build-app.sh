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
BUNDLE_ID="com.caiano.lineup"
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

# Sign with the best identity available, in order:
#   1. Developer ID Application — Apple-issued. Enables notarization (removes the Gatekeeper
#      "unidentified developer" warning) and gives a Team-ID-stable requirement, so the build
#      machine no longer has to be the one that holds a local cert. Needs --timestamp.
#   2. The local self-signed identity (Scripts/setup-signing.sh) — stable across rebuilds so
#      Accessibility persists, but NOT notarizable; users still see the Gatekeeper warning.
#   3. Ad-hoc — last resort; signature changes every build.
# We attempt the real sign rather than gating on `find-certificate` (a cert can exist with no
# usable key), then inspect the result.
# Set DEVELOPER_ID_IDENTITY to pin a specific identity; else auto-detect the first Developer
# ID Application in the keychain (excludes "Developer ID Installer", which we don't want).
DEVID="${DEVELOPER_ID_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
sig_kind="ad-hoc"
if [ -n "${DEVID}" ] && codesign --force --options runtime --timestamp \
      --sign "${DEVID}" --identifier "${BUNDLE_ID}" "${APP}" 2>/dev/null; then
  sig_kind="developer-id"
  echo "==> codesigned with Developer ID (notarizable): ${DEVID}"
elif codesign --force --options runtime --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}" 2>/dev/null; then
  sig_kind="self-signed"
  echo "==> codesigned with the local stable identity '${SIGN_IDENTITY}' (not notarizable)"
else
  echo "==> no stable identity available; ad-hoc codesign (identifier: ${BUNDLE_ID})"
  codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
fi

# The signature TCC keys on is the designated requirement. Cert-based (Developer ID or the
# self-signed cert) => stable across rebuilds, so Accessibility sticks; a bare cdhash => ad-hoc
# (re-grant on every update).
designated="$(codesign -d -r- "${APP}" 2>&1 | grep designated || true)"
if echo "${designated}" | grep -q 'certificate leaf'; then
  echo "    signature: STABLE (cert-based) — Accessibility persists across updates."
else
  echo "    signature: AD-HOC — the grant changes every build."
  echo "    Run ./Scripts/setup-signing.sh once so the permission sticks for users."
  # A release must never ship ad-hoc silently. Set REQUIRE_STABLE_SIGNATURE=1 to enforce.
  if [ "${REQUIRE_STABLE_SIGNATURE:-0}" = "1" ]; then
    echo "error: REQUIRE_STABLE_SIGNATURE=1 but the app is ad-hoc signed; refusing to ship." >&2
    exit 1
  fi
fi

# A NOTARIZED release must be Developer ID-signed: the self-signed identity is stable for
# Accessibility but Apple won't notarize it. REQUIRE_DEVELOPER_ID_SIGNATURE=1 fails here so the
# release can't silently fall back to self-signed and then fail late in notarytool.
if [ "${REQUIRE_DEVELOPER_ID_SIGNATURE:-0}" = "1" ] && [ "${sig_kind}" != "developer-id" ]; then
  echo "error: REQUIRE_DEVELOPER_ID_SIGNATURE=1 but signed with '${sig_kind}'; a Developer ID" >&2
  echo "       Application identity is required for notarization. See BUILDING.md." >&2
  exit 1
fi

# Belt-and-suspenders: the signature must at least be valid.
codesign --verify --strict "${APP}"

echo "==> done: ${APP}"
echo "    Launch with:  open \"${APP}\""
echo "    First launch will prompt for Accessibility permission."
