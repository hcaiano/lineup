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
# URL, so an entry stays valid for as long as its DMG stays hosted. Stable entries can be replaced
# for an idempotent rerun; Nightly entries must pass the strict newer-build check below first, with
# an exact same version/build/tag/asset accepted as an idempotent rerun.
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
if ! DMG_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BUNDLE_PLIST}")"; then
  echo "error: embedded Lineup.app has no CFBundleShortVersionString." >&2
  exit 1
fi
DMG_SOURCE_SHA=""
if [ "${MODE}" = "nightly" ]; then
  NUMERIC_VERSION="${VERSION%%-nightly.*}"
  if [ "${DMG_SHORT_VERSION}" != "${NUMERIC_VERSION}" ]; then
    echo "error: embedded CFBundleShortVersionString ${DMG_SHORT_VERSION} does not match Nightly base ${NUMERIC_VERSION}." >&2
    exit 1
  fi
  if ! DMG_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :LineupBuildChannel' "${BUNDLE_PLIST}")"; then
    echo "error: embedded Lineup.app has no LineupBuildChannel marker." >&2
    exit 1
  fi
  if [ "${DMG_CHANNEL}" != "nightly" ]; then
    echo "error: embedded LineupBuildChannel ${DMG_CHANNEL} is not nightly." >&2
    exit 1
  fi
  if DMG_SOURCE_DIRTY="$(/usr/libexec/PlistBuddy -c 'Print :LineupSourceDirty' "${BUNDLE_PLIST}" 2>/dev/null)"; then
    if [ "${DMG_SOURCE_DIRTY}" = "true" ]; then
      echo "error: embedded Nightly was built from a dirty checkout; refusing to appcast it." >&2
    else
      echo "error: embedded Nightly has an invalid LineupSourceDirty marker; refusing to appcast it." >&2
    fi
    exit 1
  fi
  if ! DMG_SOURCE_SHA="$(/usr/libexec/PlistBuddy -c 'Print :LineupSourceCommit' "${BUNDLE_PLIST}")"; then
    echo "error: embedded Nightly Lineup.app has no LineupSourceCommit marker." >&2
    exit 1
  fi
  if [[ ! "${DMG_SOURCE_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: embedded Nightly LineupSourceCommit must be exactly 40 lowercase hexadecimal characters." >&2
    exit 1
  fi
else
  if [ "${DMG_SHORT_VERSION}" != "${VERSION}" ]; then
    echo "error: embedded CFBundleShortVersionString ${DMG_SHORT_VERSION} does not match Stable appcast version ${VERSION}." >&2
    exit 1
  fi
  if DMG_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :LineupBuildChannel' "${BUNDLE_PLIST}" 2>/dev/null)" \
      && [ "${DMG_CHANNEL}" = "nightly" ]; then
    echo "error: embedded LineupBuildChannel nightly cannot be published on the Stable appcast." >&2
    exit 1
  fi
  if [[ "${DMG_BUILD}" =~ (d|a|b|fc)[0-9]{1,3}$ ]]; then
    echo "error: embedded build ${DMG_BUILD} has an Apple prerelease suffix and cannot be published on the Stable appcast." >&2
    exit 1
  fi
fi

if [ "${MODE}" = "nightly" ]; then
  # A Nightly enclosure must be immutable and tag-addressed. In particular, never use a moving
  # GitHub alias: Sparkle signs the local bytes while users fetch the URL later.
  if [[ "${REMOTE_URL}" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/(v[^/]+)/([^/]+\.dmg)$ ]]; then
    NIGHTLY_REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    NIGHTLY_TAG="${BASH_REMATCH[3]}"
    NIGHTLY_ASSET_NAME="${BASH_REMATCH[4]}"
  else
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
  if [ "${NIGHTLY_TAG}" != "v${VERSION}" ] || [ "${NIGHTLY_ASSET_NAME}" != "${expected_asset}" ]; then
    echo "error: Nightly enclosure must be the exact asset for v${VERSION}." >&2
    exit 1
  fi

  # Do not rely on a maintainer remembering to run the release audit first. The verifier proves
  # the repository is public, the exact release is a non-draft immutable prerelease, and the tag
  # peels to the source commit embedded in this DMG. This remains valid after a previous appcast
  # write makes the checkout dirty or advances its current HEAD.
  if ! NIGHTLY_VERIFY_OUTPUT="$(
    LINEUP_GITHUB_REPOSITORY="${NIGHTLY_REPOSITORY}" ./Scripts/nightly-release.sh --verify "${NIGHTLY_TAG}" \
      --expected-source-sha "${DMG_SOURCE_SHA}" 2>&1
  )"; then
    printf '%s\n' "${NIGHTLY_VERIFY_OUTPUT}" >&2
    echo "error: public Nightly release verification failed; refusing to appcast." >&2
    exit 1
  fi
  if ! grep -Fqx "repository=${NIGHTLY_REPOSITORY}" <<<"${NIGHTLY_VERIFY_OUTPUT}" \
      || ! grep -Fqx "tag=${NIGHTLY_TAG}" <<<"${NIGHTLY_VERIFY_OUTPUT}" \
      || ! grep -Fqx "asset_name=${expected_asset}" <<<"${NIGHTLY_VERIFY_OUTPUT}" \
      || ! grep -Fqx "asset_url=${REMOTE_URL}" <<<"${NIGHTLY_VERIFY_OUTPUT}" \
      || ! grep -Fqx "immutable=true" <<<"${NIGHTLY_VERIFY_OUTPUT}" \
      || ! grep -Fqx "source_sha=${DMG_SOURCE_SHA}" <<<"${NIGHTLY_VERIFY_OUTPUT}"; then
    echo "error: Nightly verifier output does not match the requested public release asset." >&2
    exit 1
  fi
  printf '%s\n' "${NIGHTLY_VERIFY_OUTPUT}"

  # The appcast build must be the deterministic value derived from the source Stable build and
  # the Nightly date/sequence. This is the same bounded shape emitted by nightly-release.sh and
  # lets Sparkle order a Nightly above the current Stable while keeping it below the next one.
  if ! SOURCE_STABLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"; then
    echo "error: source Info.plist has no Stable CFBundleVersion." >&2
    exit 1
  fi
  export NIGHTLY_VERSION="${VERSION}"
  export NIGHTLY_REMOTE_URL="${REMOTE_URL}"
  export NIGHTLY_SOURCE_STABLE_BUILD="${SOURCE_STABLE_BUILD}"
  if ! EXPECTED_NIGHTLY_BUILD="$(python3 - <<'PY'
import datetime
import os
import re

version = os.environ["NIGHTLY_VERSION"]
stable_build = os.environ["NIGHTLY_SOURCE_STABLE_BUILD"]
match = re.fullmatch(r"(\d+\.\d+\.\d+)-nightly\.(\d{8})\.([1-9]\d*)", version)
if not match:
    raise SystemExit("error: Nightly version has an invalid date/sequence shape.")
try:
    nightly_date = datetime.datetime.strptime(match.group(2), "%Y%m%d").date()
except ValueError:
    raise SystemExit("error: Nightly version contains an invalid calendar date.")
offset = (nightly_date - datetime.date(2026, 1, 1)).days
if not 0 <= offset <= 9998:
    raise SystemExit("error: Nightly date is outside the supported 2026-2053 range.")
if not re.fullmatch(r"[1-9]\d{0,3}", stable_build) or int(stable_build) >= 9999:
    raise SystemExit("error: source Stable CFBundleVersion must be an integer from 1 through 9998.")
sequence = int(match.group(3))
if not 1 <= sequence <= 255:
    raise SystemExit("error: Nightly sequence must be from 1 through 255.")
ordinal = offset + 1
revision, fix = divmod(ordinal, 100)
if not 0 <= revision <= 99 or not 0 <= fix <= 99:
    raise SystemExit("error: Nightly date components cannot fit the Apple version shape.")
print(f"{stable_build}.{revision:02d}.{fix:02d}a{sequence:03d}")
PY
  )"; then
    echo "error: could not derive the expected Nightly CFBundleVersion." >&2
    exit 1
  fi
  if [ "${BUILD}" != "${EXPECTED_NIGHTLY_BUILD}" ]; then
    echo "error: appcast build ${BUILD} does not match derived Nightly build ${EXPECTED_NIGHTLY_BUILD}." >&2
    exit 1
  fi
  export EXPECTED_NIGHTLY_BUILD

  # All generated Nightly versions use this exact three-component `aN` form. Comparing its
  # numeric tuple is a safe, pinned structural equivalent for Sparkle's comparator, and fails
  # closed if a hand-edited Nightly item does not follow the generated shape.
  if ! NIGHTLY_APPCAST_MAX="$(python3 - <<'PY'
import os
import re
import xml.etree.ElementTree as ET

path = "web/appcast.xml"
candidate = os.environ["EXPECTED_NIGHTLY_BUILD"]
candidate_short_version = os.environ["NIGHTLY_VERSION"]
candidate_url = os.environ["NIGHTLY_REMOTE_URL"]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

def key(version):
    match = re.fullmatch(r"([1-9]\d{0,3})\.(\d{2})\.(\d{2})a(\d{3})", version)
    if not match:
        raise SystemExit(f"error: Nightly appcast version {version!r} is not a generated Apple prerelease.")
    sequence = int(match.group(4))
    if not 1 <= sequence <= 255:
        raise SystemExit(f"error: Nightly appcast version {version!r} has an invalid sequence.")
    return tuple(int(part) for part in match.groups())

candidate_key = key(candidate)
if not os.path.exists(path):
    print("none")
    raise SystemExit(0)
try:
    root = ET.parse(path).getroot()
except ET.ParseError as error:
    raise SystemExit(f"error: {path} is not valid XML: {error}")

existing = []
for item in root.iter("item"):
    channel_node = item.find(f"{sparkle}channel")
    if channel_node is None or (channel_node.text or "").strip() != "nightly":
        continue
    version_node = item.find(f"{sparkle}version")
    if version_node is None or not (version_node.text or "").strip():
        raise SystemExit("error: a Nightly appcast item has no sparkle:version.")
    version = version_node.text.strip()
    short_version_node = item.find(f"{sparkle}shortVersionString")
    enclosure_node = item.find("enclosure")
    if short_version_node is None or enclosure_node is None or not enclosure_node.get("url"):
        raise SystemExit("error: a Nightly appcast item has incomplete version or asset metadata.")
    existing.append((key(version), version, short_version_node.text or "", enclosure_node.get("url")))

if not existing:
    print("none")
    raise SystemExit(0)
older = []
for existing_key, version, short_version, url in existing:
    if candidate_key == existing_key:
        if short_version == candidate_short_version and url == candidate_url:
            continue
        raise SystemExit(
            f"error: Nightly build {candidate} matches appcast build {version} but not its exact version/asset."
        )
    if candidate_key <= existing_key:
        raise SystemExit(
            f"error: Nightly build {candidate} is not strictly newer than appcast Nightly {version}."
        )
    older.append((existing_key, version))
print(max(older)[1] if older else "none")
PY
  )"; then
    echo "error: existing Nightly appcast items are not strictly older than the candidate." >&2
    exit 1
  fi
  if [ "${NIGHTLY_APPCAST_MAX}" != "none" ]; then
    echo "    prior Nightly appcast maximum: ${NIGHTLY_APPCAST_MAX}"
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
  # the exact tag, source commit marker, and asset before the feed changes; this script
  # deliberately does not upload, create, or mutate a GitHub release.
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
