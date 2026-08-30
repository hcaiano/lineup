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

# The checked-in plist describes the public Stable build. A Nightly package must opt in
# explicitly, including its numeric X.Y.Z bundle display version and its Apple-valid prerelease
# bundle version; the T3 Nightly display version belongs to its tag and appcast item.
PLIST_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :LineupBuildChannel' Resources/Info.plist 2>/dev/null || echo stable)"
BUILD_CHANNEL="${LINEUP_BUILD_CHANNEL:-${PLIST_CHANNEL}}"
VERSION_OVERRIDE="${LINEUP_VERSION:-}"
BUILD_OVERRIDE="${LINEUP_BUILD_VERSION:-}"

case "${BUILD_CHANNEL}" in
  stable|nightly) ;;
  *)
    echo "error: LINEUP_BUILD_CHANNEL must be 'stable' or 'nightly' (got '${BUILD_CHANNEL}')." >&2
    exit 1
    ;;
esac

if [ "${BUILD_CHANNEL}" = "nightly" ] && { [ -z "${VERSION_OVERRIDE}" ] || [ -z "${BUILD_OVERRIDE}" ]; }; then
  echo "error: Nightly builds require LINEUP_VERSION and LINEUP_BUILD_VERSION overrides." >&2
  echo "       Use Scripts/nightly-release.sh to resolve both values." >&2
  exit 1
fi

# CFBundleVersion is numeric with an optional Apple development suffix. Keep this validation next
# to the override so a malformed prerelease cannot reach Sparkle with an unorderable version.
if [ -n "${BUILD_OVERRIDE}" ] && [[ ! "${BUILD_OVERRIDE}" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}(\.[0-9]{1,2})?)?((d|a|b|fc)[0-9]{1,3})?$ ]]; then
  echo "error: LINEUP_BUILD_VERSION '${BUILD_OVERRIDE}' is not an Apple-valid CFBundleVersion." >&2
  exit 1
fi
if [ -n "${BUILD_OVERRIDE}" ] && [[ "${BUILD_OVERRIDE}" =~ (d|a|b|fc)([0-9]+)$ ]]; then
  suffix_number="${BASH_REMATCH[2]}"
  if [ "${suffix_number}" -lt 1 ] || [ "${suffix_number}" -gt 255 ]; then
    echo "error: LINEUP_BUILD_VERSION suffix number must be from 1 through 255." >&2
    exit 1
  fi
fi
if [ "${BUILD_CHANNEL}" = "nightly" ] && [[ ! "${BUILD_OVERRIDE}" =~ (d|a|b|fc)[0-9]{1,3}$ ]]; then
  echo "error: Nightly LINEUP_BUILD_VERSION must include an Apple prerelease suffix." >&2
  exit 1
fi

if [ -n "${VERSION_OVERRIDE}" ] && [[ ! "${VERSION_OVERRIDE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: LINEUP_VERSION '${VERSION_OVERRIDE}' is not a three-part release version." >&2
  exit 1
fi

SOURCE_SHA=""
SOURCE_DIRTY=0
if [ "${BUILD_CHANNEL}" = "nightly" ]; then
  # A Nightly artifact must carry proof of the exact source commit that the public tag names.
  # Do not allow a dirty checkout: embedding HEAD while local edits are present would make the
  # marker look authoritative even though those edits also went into the built app.
  SOURCE_SHA="$(git rev-parse HEAD 2>/dev/null)" || {
    echo "error: Nightly builds must run inside the Lineup Git checkout." >&2
    exit 1
  }
  [[ "${SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "error: Nightly source commit is not a 40-character Git SHA." >&2
    exit 1
  }
  WORKTREE_STATE="$(git status --porcelain --untracked-files=all)"
  if [ -n "${WORKTREE_STATE}" ]; then
    if [ "${LINEUP_ALLOW_DIRTY:-0}" = "1" ]; then
      echo "WARNING: LINEUP_ALLOW_DIRTY=1 is for local Nightly bundle tests only; never release this build." >&2
      SOURCE_DIRTY=1
    else
      echo "error: Nightly builds require a clean checkout; source edits would invalidate the embedded commit." >&2
      exit 1
    fi
  fi
fi

# The source snapshot must remain stable while Swift compiles and while the bundle is assembled.
# A clean release checkout must still be clean; the explicit dirty escape is only for local tests
# and must remain marked dirty so it cannot pass the Nightly appcast gate.
validate_source_snapshot() {
  local phase="${1}"
  local current_sha current_state
  if ! current_sha="$(git rev-parse HEAD 2>/dev/null)"; then
    echo "error: could not re-read the Nightly source commit after ${phase}." >&2
    exit 1
  fi
  if [ "${current_sha}" != "${SOURCE_SHA}" ]; then
    echo "error: Nightly source HEAD changed during ${phase}; refusing to assemble the bundle." >&2
    exit 1
  fi
  if ! current_state="$(git status --porcelain --untracked-files=all)"; then
    echo "error: could not re-check the Nightly checkout after ${phase}." >&2
    exit 1
  fi
  if [ "${SOURCE_DIRTY}" -eq 0 ] && [ -n "${current_state}" ]; then
    echo "error: Nightly checkout became dirty during ${phase}; refusing to assemble the bundle." >&2
    exit 1
  fi
  if [ "${SOURCE_DIRTY}" -eq 1 ] && [ -z "${current_state}" ]; then
    echo "error: the test-only dirty Nightly checkout became clean during ${phase}; refusing to clear its dirty marker." >&2
    exit 1
  fi
}

# Build the release executable. Universal (arm64 + x86_64) by default so the app runs on every
# supported Mac; UNIVERSAL=0 builds host-arch only (faster local iteration). The one-shot
# `--arch a --arch b` needs full Xcode (xcbuild); under Command Line Tools we build each slice
# with --triple into its own scratch path and lipo them.
UNIVERSAL="${UNIVERSAL:-1}"
if [ "${UNIVERSAL}" = "1" ]; then
  echo "==> swift build -c release (universal: arm64 + x86_64)"
  ARM_SCRATCH=".build/uni-arm64"; X86_SCRATCH=".build/uni-x86_64"
  swift build -c release --triple arm64-apple-macosx13.0  --scratch-path "${ARM_SCRATCH}"
  swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path "${X86_SCRATCH}"
  mkdir -p ".build/uni-universal/release"
  lipo -create \
    "${ARM_SCRATCH}/arm64-apple-macosx/release/${EXEC_NAME}" \
    "${X86_SCRATCH}/x86_64-apple-macosx/release/${EXEC_NAME}" \
    -output ".build/uni-universal/release/${EXEC_NAME}"
  EXEC_SRC=".build/uni-universal/release/${EXEC_NAME}"
  # Sparkle's XCFramework macOS slice is already universal; take it from the arm64 build.
  SPARKLE_SEARCH_DIR="${ARM_SCRATCH}/arm64-apple-macosx/release"
  SPARKLE_LICENSE="${ARM_SCRATCH}/checkouts/Sparkle/LICENSE"
else
  echo "==> swift build -c release (host arch only)"
  swift build -c release
  EXEC_SRC="${BUILD_DIR}/${EXEC_NAME}"
  SPARKLE_SEARCH_DIR="${BUILD_DIR}"
  SPARKLE_LICENSE=".build/checkouts/Sparkle/LICENSE"
fi

if [ "${BUILD_CHANNEL}" = "nightly" ]; then
  validate_source_snapshot "compilation"
fi

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
cp "${EXEC_SRC}" "${APP}/Contents/MacOS/${EXEC_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"

# Keep the source plist Stable so ordinary builds preserve the existing release identity. Variant
# metadata belongs in the assembled bundle and is inspectable with PlistBuddy after the build.
if [ -n "${VERSION_OVERRIDE}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION_OVERRIDE}" \
    "${APP}/Contents/Info.plist"
fi
if [ -n "${BUILD_OVERRIDE}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_OVERRIDE}" \
    "${APP}/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :LineupBuildChannel ${BUILD_CHANNEL}" \
  "${APP}/Contents/Info.plist"
if [ "${BUILD_CHANNEL}" = "nightly" ]; then
  validate_source_snapshot "bundle assembly"
  if [ "${SOURCE_DIRTY}" -eq 1 ]; then
    # A dirty test bundle must remain useful for local inspection but can never pass the
    # Nightly appcast proof. The prefix is deliberately not a Git SHA; the appcast rejects it.
    SOURCE_MARKER="dirty-${SOURCE_SHA}"
    /usr/libexec/PlistBuddy -c "Add :LineupSourceDirty bool true" \
      "${APP}/Contents/Info.plist"
  else
    SOURCE_MARKER="${SOURCE_SHA}"
  fi
  /usr/libexec/PlistBuddy -c "Add :LineupSourceCommit string ${SOURCE_MARKER}" \
    "${APP}/Contents/Info.plist"
fi

# Fail closed if the real Sparkle public key was never filled in: a placeholder SUPublicEDKey
# ships an app that can never validate an update (users would have to reinstall by hand).
if grep -q 'REPLACE_WITH_SUPublicEDKey' "${APP}/Contents/Info.plist"; then
  echo "error: Info.plist still has the placeholder SUPublicEDKey." >&2
  echo "       Run ./Scripts/sparkle-keygen.sh and paste the public key into Resources/Info.plist." >&2
  exit 1
fi
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
cp "LICENSE" "${APP}/Contents/Resources/Lineup-LICENSE.txt"
if [ ! -f "${SPARKLE_LICENSE}" ]; then
  echo "error: Sparkle licence notices not found at '${SPARKLE_LICENSE}'." >&2
  exit 1
fi
cp "${SPARKLE_LICENSE}" "${APP}/Contents/Resources/Sparkle-LICENSE.txt"

# SwiftPM puts a target's declared resources (the per-tool icons) in a bundle NEXT TO the
# product, not inside it. This script assembles the .app by hand, so it has to carry that bundle
# across. The app's tool-icon loader reads it from Contents/Resources; without this the Settings
# sidebar and tool headers safely fall back to drawn icons in the shipped app.
RES_BUNDLE="${SPARKLE_SEARCH_DIR}/${EXEC_NAME}_${EXEC_NAME}.bundle"
if [ ! -d "${RES_BUNDLE}" ]; then
  echo "error: resource bundle '${RES_BUNDLE}' not found; run 'swift build -c release' first." >&2
  exit 1
fi
ditto "${RES_BUNDLE}" "${APP}/Contents/Resources/$(basename "${RES_BUNDLE}")"

# Embed Sparkle.framework (auto-updates). SwiftPM copies the binary XCFramework's macOS slice
# next to the product; fall back to the extracted artifact. ditto (not cp) preserves the
# framework's Versions symlink structure — a plain copy would break its signature.
SPARKLE_FW="${SPARKLE_SEARCH_DIR}/Sparkle.framework"
[ -d "${SPARKLE_FW}" ] || SPARKLE_FW="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' 2>/dev/null | head -1)"
[ -d "${SPARKLE_FW}" ] || { echo "error: Sparkle.framework not found; run 'swift build -c release' first." >&2; exit 1; }
mkdir -p "${APP}/Contents/Frameworks"
ditto "${SPARKLE_FW}" "${APP}/Contents/Frameworks/Sparkle.framework"

# Resolve the signing identity by ATTEMPTING the sign on the bundled executable (a probe that
# proves the key is actually usable), in order:
#   1. Developer ID Application — Apple-issued. Enables notarization (removes the Gatekeeper
#      "unidentified developer" warning) and gives a Team-ID-stable requirement. Needs --timestamp.
#   2. The local self-signed identity (Scripts/setup-signing.sh) — stable across rebuilds so
#      Accessibility persists, but NOT notarizable; users still see the Gatekeeper warning.
#   3. Ad-hoc — last resort; signature changes every build.
# find-identity is reliable for Developer ID but NOT for the untrusted self-signed cert: codesign
# can sign with "Lineup Self-Signed" even when `find-identity -v` reports zero valid identities,
# so the self-signed tier must be PROBED, not queried (matches setup-signing.sh). The probe sign
# is overwritten by the final inside-out sign below. DEVELOPER_ID_IDENTITY pins a specific one.
PROBE="${APP}/Contents/MacOS/${EXEC_NAME}"
DEVID="${DEVELOPER_ID_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
TIMESTAMP_FLAG=""
if [ -n "${DEVID}" ] && codesign --force --options runtime --sign "${DEVID}" "${PROBE}" 2>/dev/null; then
  SIGN_ID="${DEVID}"; sig_kind="developer-id"; TIMESTAMP_FLAG="--timestamp"
  echo "==> signing with Developer ID (notarizable): ${DEVID}"
elif codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${PROBE}" 2>/dev/null; then
  SIGN_ID="${SIGN_IDENTITY}"; sig_kind="self-signed"
  echo "==> signing with the local stable identity '${SIGN_IDENTITY}' (not notarizable)"
else
  SIGN_ID="-"; sig_kind="ad-hoc"
  echo "==> no stable identity; ad-hoc signing (identifier: ${BUNDLE_ID})"
fi

# Hardened runtime (--options runtime) ONLY for Developer ID. Hardened Runtime turns on Library
# Validation, which requires every loaded library to be Apple-signed or share the app's Team ID.
# A self-signed or ad-hoc build has no Team ID, so a hardened app would pass `codesign --verify`
# but FAIL AT LAUNCH when dyld loads the embedded Sparkle.framework. Developer ID has a Team ID
# (and needs hardened runtime for notarization), so harden only then; local builds sign without it.
RUNTIME_FLAG=""
[ "${sig_kind}" = "developer-id" ] && RUNTIME_FLAG="--options runtime"

# Sign the embedded Sparkle.framework INSIDE-OUT: each nested helper/XPC service first, then the
# framework itself. Apple requires inner code signed before its container, and Sparkle's own docs
# say to sign these individually and NEVER with --deep (it mis-signs the components).
# Downloader.xpc keeps its own entitlements.
FW="${APP}/Contents/Frameworks/Sparkle.framework"
if [ -d "${FW}" ]; then
  codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --sign "${SIGN_ID}" "${FW}/Versions/B/XPCServices/Installer.xpc"
  codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --preserve-metadata=entitlements --sign "${SIGN_ID}" "${FW}/Versions/B/XPCServices/Downloader.xpc"
  codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --sign "${SIGN_ID}" "${FW}/Versions/B/Autoupdate"
  codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --sign "${SIGN_ID}" "${FW}/Versions/B/Updater.app"
  codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --sign "${SIGN_ID}" "${FW}"
fi

# NOTE: the SwiftPM resource bundle is deliberately NOT signed on its own. It is a FLAT bundle
# (Info.plist at the root, no Contents/), which codesign rejects with "bundle format
# unrecognized"; it carries no executable code, so the app's own signature seals it as data.
#
# Sign the app LAST (identifier pinned). This seals the embedded framework.
codesign --force ${RUNTIME_FLAG} ${TIMESTAMP_FLAG} --sign "${SIGN_ID}" --identifier "${BUNDLE_ID}" "${APP}"

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

# Belt-and-suspenders: the whole bundle (app + embedded framework) must verify.
codesign --verify --deep --strict "${APP}"

# Fail closed on a universal build if either shipped binary isn't actually fat — e.g. a --triple
# build silently produced one arch — instead of relying on manual `lipo -info` inspection.
if [ "${UNIVERSAL}" = "1" ]; then
  lipo "${APP}/Contents/MacOS/${EXEC_NAME}" -verify_arch arm64 x86_64 \
    || { echo "error: ${EXEC_NAME} is not universal (arm64 + x86_64)." >&2; exit 1; }
  lipo "${FW}/Versions/B/Sparkle" -verify_arch arm64 x86_64 \
    || { echo "error: embedded Sparkle.framework is not universal (arm64 + x86_64)." >&2; exit 1; }
  echo "    arch: universal (arm64 + x86_64) verified."
fi

echo "==> done: ${APP}"
echo "    channel: ${BUILD_CHANNEL}"
echo "    Launch with:  open \"${APP}\""
echo "    First launch will prompt for Accessibility permission."
