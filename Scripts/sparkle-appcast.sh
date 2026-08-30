#!/usr/bin/env bash
# Add a notarized release DMG to web/appcast.xml, EdDSA-signed with the Sparkle key.
#
# Stable downloads are SELF-HOSTED: the DMG is staged into web/downloads/ and the enclosure points
# at https://lineup.caiano.com/downloads/<file>. Nightly items may point at a public, immutable
# GitHub prerelease asset after this script proves that the remote bytes equal the local DMG.
#
# Usage:
#   ./Scripts/sparkle-appcast.sh <path-to-dmg> [version] [build]
#   ./Scripts/sparkle-appcast.sh --nightly <path-to-dmg> <public-github-asset-url> [version] [build]
#   version/build default to Resources/Info.plist (the just-released values).
#   Stable mode stages the DMG under web/downloads/. Nightly mode signs the local DMG but keeps
#   the enclosure pointed at the exact, tagged GitHub prerelease asset, so every Nightly DMG need
#   not be committed to this repository.
#
# Requires: the EdDSA PRIVATE key in your login Keychain (run Scripts/sparkle-keygen.sh once).
#
# Release notes: if web/release-notes/<version>.html exists it is inlined as the item
# <description> AND linked from sparkle:releaseNotesLink. Keep that file an HTML FRAGMENT (no
# <html>/<body> wrapper). The link is EXTENSIONLESS (/release-notes/<version>): Cloudflare's
# asset server defaults to html_handling = auto-trailing-slash, which serves foo.html at /foo
# and 404s the .html URL itself.
#
# Prior <item> entries are PRESERVED verbatim — their EdDSA signatures cover the file, not the
# URL, so an entry stays valid for as long as its DMG stays hosted. Only an entry for the same
# version is replaced (re-running this for one version is idempotent).
set -euo pipefail
cd "$(dirname "$0")/.."

SITE="https://lineup.caiano.com"

MODE="stable"
REMOTE_URL=""
if [ "${1:-}" = "--nightly" ]; then
  MODE="nightly"
  shift
  DMG="${1:?usage: sparkle-appcast.sh --nightly <dmg> <github-asset-url> [version] [build]}"
  REMOTE_URL="${2:?usage: sparkle-appcast.sh --nightly <dmg> <github-asset-url> [version] [build]}"
  shift 2
else
  DMG="${1:?usage: sparkle-appcast.sh <dmg> [version] [build]}"
  shift
fi
[ -f "${DMG}" ] || { echo "no such DMG: ${DMG}" >&2; exit 1; }

# Sparkle's CLI ships inside the SwiftPM artifact; build once so it's present.
swift build >/dev/null 2>&1 || true
SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -not -path '*old_dsa*' 2>/dev/null | head -1)"
[ -x "${SIGN_UPDATE}" ] || { echo "error: sign_update not found; run 'swift build' first." >&2; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"

REMOTE_COPY=""
DMG_MOUNT=""
DMG_ATTACHED=0
cleanup() {
  if [ -n "${REMOTE_COPY}" ]; then
    rm -f -- "${REMOTE_COPY}"
  fi
  if [ "${DMG_ATTACHED}" -eq 1 ]; then
    hdiutil detach "${DMG_MOUNT}" >/dev/null 2>&1 || true
    DMG_ATTACHED=0
  fi
  if [ -n "${DMG_MOUNT}" ] && [ -d "${DMG_MOUNT}" ]; then
    rmdir "${DMG_MOUNT}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "${MODE}" = "nightly" ]; then
  # A Nightly enclosure must be immutable and tag-addressed. In particular, never use a moving
  # GitHub alias: Sparkle signs the local bytes while users fetch the URL later.
  if [[ ! "${REMOTE_URL}" =~ ^https://github\.com/[^/]+/[^/]+/releases/download/v[^/]+/[^/]+\.dmg$ ]]; then
    echo "error: Nightly enclosure must be an exact tagged GitHub release asset URL." >&2
    exit 1
  fi
  if [[ "${REMOTE_URL}" == *latest* ]]; then
    echo "error: Nightly enclosure may not use a moving GitHub release alias." >&2
    exit 1
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[1-9][0-9]*$ ]]; then
    echo "error: Nightly appcast version must be X.Y.Z-nightly.YYYYMMDD.sequence." >&2
    exit 1
  fi
  if [[ ! "${BUILD}" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}(\.[0-9]{1,2})?)?((d|a|b|fc)[0-9]{1,3})?$ ]]; then
    echo "error: Nightly build '${BUILD}' is not an Apple-valid CFBundleVersion." >&2
    exit 1
  fi
  if [[ "${BUILD}" =~ (d|a|b|fc)([0-9]+)$ ]]; then
    suffix_number="${BASH_REMATCH[2]}"
    if [ "${suffix_number}" -lt 1 ] || [ "${suffix_number}" -gt 255 ]; then
      echo "error: Nightly build suffix number must be from 1 through 255." >&2
      exit 1
    fi
  fi
  if [[ ! "${BUILD}" =~ (d|a|b|fc)[0-9]{1,3}$ ]]; then
    echo "error: Nightly build must include an Apple prerelease suffix." >&2
    exit 1
  fi
  expected_asset="Lineup-${VERSION}.dmg"
  if [[ "${REMOTE_URL}" != */releases/download/v${VERSION}/${expected_asset} ]]; then
    echo "error: Nightly enclosure must be the exact asset for v${VERSION}." >&2
    exit 1
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to compare the public Nightly asset." >&2
    exit 1
  }
  command -v cmp >/dev/null 2>&1 || {
    echo "error: cmp is required to compare the public Nightly asset." >&2
    exit 1
  }
  REMOTE_COPY="$(mktemp "${TMPDIR:-/tmp}/lineup-nightly-asset.XXXXXX")"
  if ! curl --fail --location --silent --show-error --output "${REMOTE_COPY}" "${REMOTE_URL}"; then
    echo "error: could not download the exact public Nightly asset for comparison." >&2
    exit 1
  fi
  if ! cmp -s "${DMG}" "${REMOTE_COPY}"; then
    echo "error: public Nightly asset bytes differ from the local DMG; refusing to appcast." >&2
    exit 1
  fi
fi

# Read the metadata from the actual DMG that will be signed. This catches a stale or mismatched
# app bundle before the appcast can point users at it. Nightly also keeps the display version
# numeric inside the bundle while exposing its date/sequence only in the public release version.
command -v hdiutil >/dev/null 2>&1 || {
  echo "error: hdiutil is required to inspect the embedded Lineup.app." >&2
  exit 1
}
DMG_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/lineup-appcast-mount.XXXXXX")"
if ! hdiutil attach -nobrowse -noverify -readonly -mountpoint "${DMG_MOUNT}" "${DMG}" >/dev/null; then
  echo "error: could not mount ${DMG} to inspect its embedded Lineup.app." >&2
  exit 1
fi
DMG_ATTACHED=1
BUNDLE_PLIST="${DMG_MOUNT}/Lineup.app/Contents/Info.plist"
[ -f "${BUNDLE_PLIST}" ] || {
  echo "error: ${DMG} does not contain Lineup.app/Contents/Info.plist." >&2
  exit 1
}
if ! DMG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${BUNDLE_PLIST}")"; then
  echo "error: embedded Lineup.app has no CFBundleVersion." >&2
  exit 1
fi
if [ "${DMG_BUILD}" != "${BUILD}" ]; then
  echo "error: embedded CFBundleVersion ${DMG_BUILD} does not match appcast build ${BUILD}." >&2
  exit 1
fi
if [ "${MODE}" = "nightly" ]; then
  NUMERIC_VERSION="${VERSION%%-nightly.*}"
  if ! DMG_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BUNDLE_PLIST}")"; then
    echo "error: embedded Lineup.app has no CFBundleShortVersionString." >&2
    exit 1
  fi
  if [ "${DMG_SHORT_VERSION}" != "${NUMERIC_VERSION}" ]; then
    echo "error: embedded CFBundleShortVersionString ${DMG_SHORT_VERSION} does not match Nightly base ${NUMERIC_VERSION}." >&2
    exit 1
  fi
fi

# FAIL CLOSED: only ever EdDSA-sign a real, notarized, stapled Developer ID DMG. Once an
# enclosure lands in web/appcast.xml, Sparkle clients trust its archive signature and install it
# without a Gatekeeper prompt — so appcasting an unsigned / pre-notarization / ad-hoc / stale DMG
# by accident would hand auto-update users a binary that bypassed the guarantees a normal
# download enforces. Require the same acceptance as a release before signing.
# (Capture codesign output first: piping it into `grep -q` makes codesign die with SIGPIPE under
# `set -o pipefail`, a false negative.)
sig_info="$(codesign -dvvv "${DMG}" 2>&1 || true)"
if ! grep -q 'Authority=Developer ID Application' <<<"${sig_info}"; then
  echo "error: ${DMG} is not Developer ID-signed; refusing to appcast it." >&2; exit 1
fi
if ! spctl -a -vvv -t open --context context:primary-signature "${DMG}" 2>/dev/null; then
  echo "error: ${DMG} is not notarized / not accepted by Gatekeeper; refusing to appcast it." >&2; exit 1
fi
if ! xcrun stapler validate "${DMG}" >/dev/null 2>&1; then
  echo "error: ${DMG} is not stapled; run ./Scripts/notarize.sh \"${DMG}\" first." >&2; exit 1
fi

# Publish the download BEFORE signing it, so the bytes the signature covers are exactly the
# bytes the enclosure URL serves. (Stapling rewrites the DMG, so signing a copy staged earlier
# would be a silent mismatch.)
FILENAME="$(basename "${DMG}")"
if [ "${MODE}" = "stable" ]; then
  mkdir -p web/downloads
  ditto "${DMG}" "web/downloads/${FILENAME}"
  SIGN_PATH="web/downloads/${FILENAME}"
  ENCLOSURE_URL="${SITE}/downloads/${FILENAME}"
else
  # Sign the exact local bytes that the public release asset must contain. The helper verifies
  # the exact tag and asset before this script is called; this script deliberately does not
  # upload, create, or mutate a GitHub release.
  SIGN_PATH="${DMG}"
  ENCLOSURE_URL="${REMOTE_URL}"
fi

# sign_update prints e.g.  sparkle:edSignature="…" length="12345"
# (it reads the private key from the Keychain; fails loudly if the key is missing).
SIG_LINE="$("${SIGN_UPDATE}" "${SIGN_PATH}")"
DATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

export APPCAST_URL="${ENCLOSURE_URL}"
export APPCAST_SITE="${SITE}"
export APPCAST_VERSION="${VERSION}"
export APPCAST_BUILD="${BUILD}"
export APPCAST_SIG_LINE="${SIG_LINE}"
export APPCAST_DATE="${DATE}"
export APPCAST_NOTES_FILE="web/release-notes/${VERSION}.html"
export APPCAST_CHANNEL="${MODE}"

python3 - <<'PY'
import html, os, re, sys

path = "web/appcast.xml"
version = os.environ["APPCAST_VERSION"]
site = os.environ["APPCAST_SITE"]

notes_file = os.environ["APPCAST_NOTES_FILE"]
channel = os.environ["APPCAST_CHANNEL"]
download_comment = (
    "Stable downloads are self-hosted under /downloads/. Nightly assets are exact tagged public GitHub prereleases."
    if channel == "nightly"
    else "Downloads are self-hosted under /downloads/."
)
notes_lines = []
if channel == "nightly":
    notes_lines.append("      <sparkle:channel>nightly</sparkle:channel>")
if os.path.exists(notes_file):
    with open(notes_file, encoding="utf-8") as fh:
        fragment = fh.read().strip()
    if "]]>" in fragment:
        sys.exit(f"error: {notes_file} contains ']]>', which cannot be inlined in CDATA.")
    notes_lines.append(
        f"      <sparkle:releaseNotesLink>{site}/release-notes/{version}</sparkle:releaseNotesLink>"
    )
    body = "\n".join("        " + line for line in fragment.splitlines())
    notes_lines.append(f"      <description><![CDATA[\n{body}\n      ]]></description>")

item = "\n".join(
    [
        "    <item>",
        f"      <title>Lineup {html.escape(version)}</title>",
        f"      <link>{site}/</link>",
        f"      <sparkle:version>{os.environ['APPCAST_BUILD']}</sparkle:version>",
        f"      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>",
        *notes_lines,
        "      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>",
        f"      <pubDate>{os.environ['APPCAST_DATE']}</pubDate>",
        f'      <enclosure url="{os.environ["APPCAST_URL"]}" type="application/octet-stream" '
        f"{os.environ['APPCAST_SIG_LINE']} />",
        "    </item>",
    ]
)

# Keep every prior entry verbatim (their signatures cover the file, not the URL); replace only
# an entry for this same version, so re-running the script is idempotent.
previous = ""
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        previous = fh.read()
kept = [
    block
    for block in re.findall(r"^ *<item>.*?</item>", previous, re.S | re.M)
    if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in block
]

with open(path, "w", encoding="utf-8") as fh:
    fh.write(
        "\n".join(
            [
                '<?xml version="1.0" encoding="utf-8"?>',
                "<!-- Sparkle update feed for Lineup. Regenerated by Scripts/sparkle-appcast.sh per release. "
                + download_comment
                + " -->",
                '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'
                ' xmlns:dc="http://purl.org/dc/elements/1.1/">',
                "  <channel>",
                "    <title>Lineup</title>",
                f"    <link>{site}/appcast.xml</link>",
                "    <description>Updates for Lineup, a macOS utilities suite.</description>",
                "    <language>en</language>",
                item,
                *kept,
                "  </channel>",
                "</rss>",
                "",
            ]
        )
    )
PY

echo "==> wrote web/appcast.xml for Lineup ${VERSION} (build ${BUILD})"
echo "    enclosure: ${APPCAST_URL}"
if [ "${MODE}" = "stable" ]; then
  echo "    staged:    web/downloads/$(basename "${DMG}")"
  echo "    Next: deploy web/ (npx wrangler deploy) and commit web/appcast.xml + web/downloads/."
else
  echo "    channel:   nightly"
  echo "    Next: deploy web/ (npx wrangler deploy) and commit web/appcast.xml only."
fi
