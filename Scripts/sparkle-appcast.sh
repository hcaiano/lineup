#!/usr/bin/env bash
# Add a notarized release DMG to web/appcast.xml, EdDSA-signed with the Sparkle key.
#
# Downloads are SELF-HOSTED: the DMG is staged into web/downloads/ and the enclosure points at
# https://lineup.caiano.com/downloads/<file>. Nothing in the feed depends on GitHub, so the
# source repository can be private without breaking auto-updates for installed copies.
#
# Usage: ./Scripts/sparkle-appcast.sh <path-to-dmg> [version] [build]
#   version/build default to Resources/Info.plist (the just-released values).
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

DMG="${1:?usage: sparkle-appcast.sh <dmg> [version] [build]}"
[ -f "${DMG}" ] || { echo "no such DMG: ${DMG}" >&2; exit 1; }

# Sparkle's CLI ships inside the SwiftPM artifact; build once so it's present.
swift build >/dev/null 2>&1 || true
SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -not -path '*old_dsa*' 2>/dev/null | head -1)"
[ -x "${SIGN_UPDATE}" ] || { echo "error: sign_update not found; run 'swift build' first." >&2; exit 1; }

VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD="${3:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"

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
mkdir -p web/downloads
ditto "${DMG}" "web/downloads/${FILENAME}"

# sign_update prints e.g.  sparkle:edSignature="…" length="12345"
# (it reads the private key from the Keychain; fails loudly if the key is missing).
SIG_LINE="$("${SIGN_UPDATE}" "web/downloads/${FILENAME}")"
DATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

export APPCAST_URL="${SITE}/downloads/${FILENAME}"
export APPCAST_SITE="${SITE}"
export APPCAST_VERSION="${VERSION}"
export APPCAST_BUILD="${BUILD}"
export APPCAST_SIG_LINE="${SIG_LINE}"
export APPCAST_DATE="${DATE}"
export APPCAST_NOTES_FILE="web/release-notes/${VERSION}.html"

python3 - <<'PY'
import html, os, re, sys

path = "web/appcast.xml"
version = os.environ["APPCAST_VERSION"]
site = os.environ["APPCAST_SITE"]

notes_file = os.environ["APPCAST_NOTES_FILE"]
notes_lines = []
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
                "<!-- Sparkle update feed for Lineup. Regenerated by Scripts/sparkle-appcast.sh per release."
                " Downloads are self-hosted under /downloads/. -->",
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
echo "    staged:    web/downloads/$(basename "${DMG}")"
echo "    Next: deploy web/ (npx wrangler deploy) and commit web/appcast.xml + web/downloads/."
