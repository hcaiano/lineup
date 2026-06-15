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

# Prefer the stable self-signed identity; fall back to ad-hoc. We TRY to sign with the
# identity rather than gating on `find-certificate` — a cert can be present with no usable
# private key (e.g. a half-finished import), and `find-identity -v` reports zero for an
# untrusted self-signed cert even when codesign can use it. So: attempt the real sign,
# then inspect the result.
signed_stable=0
if codesign --force --options runtime --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}" 2>/dev/null; then
  signed_stable=1
  echo "==> codesigned with stable identity '${SIGN_IDENTITY}'"
else
  echo "==> '${SIGN_IDENTITY}' unavailable; ad-hoc codesign (identifier: ${BUNDLE_ID})"
  codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
fi

# The signature TCC keys on is the designated requirement. Cert-based => stable across
# rebuilds (Accessibility sticks); a bare cdhash => ad-hoc (re-grant on every update).
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

# Belt-and-suspenders: the signature must at least be valid.
codesign --verify --strict "${APP}"

echo "==> done: ${APP}"
echo "    Launch with:  open \"${APP}\""
echo "    First launch will prompt for Accessibility permission."
