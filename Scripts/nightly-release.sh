#!/usr/bin/env bash
# Resolve the metadata for one public Nightly release.
#
# This helper is intentionally read-only outside the checkout. It reads public GitHub release
# metadata with `gh api`, chooses an explicit tag, and prints the values needed by build-app.sh
# and sparkle-appcast.sh. It never creates, uploads, edits, or deletes a GitHub release, and it
# never pushes a tag or deploys the website.
#
# Usage:
#   ./Scripts/nightly-release.sh
#   LINEUP_NIGHTLY_DATE=20260830 LINEUP_NIGHTLY_SEQUENCE=3 ./Scripts/nightly-release.sh
#   ./Scripts/nightly-release.sh --verify <exact-nightly-tag>
#
# The default output is a shell-friendly plan. Pass the printed values explicitly:
#   LINEUP_BUILD_CHANNEL=nightly \
#   LINEUP_VERSION=<next_patch> LINEUP_BUILD_VERSION=<bundle-version> \
#   ./Scripts/build-app.sh dist-nightly
#
# After a trusted, notarized DMG is attached to the exact public prerelease tag, use the printed
# asset URL with `Scripts/sparkle-appcast.sh --nightly`. The enclosure is tag-addressed; it never
# uses a moving GitHub alias.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null 2>&1 || {
  echo "error: gh CLI is required to read public GitHub release metadata." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to parse GitHub release metadata." >&2
  exit 1
}

SOURCE_SHA="$(git rev-parse HEAD 2>/dev/null)" || {
  echo "error: this helper must run inside the Lineup Git checkout." >&2
  exit 1
}
export NIGHTLY_SOURCE_SHA="${SOURCE_SHA}"
WORKTREE_STATE="$(git status --porcelain --untracked-files=all)"
if [ -n "${WORKTREE_STATE}" ] && [ "${LINEUP_ALLOW_DIRTY:-0}" != "1" ]; then
  echo "error: the checkout is dirty; resolve it before planning a release." >&2
  echo "       Set LINEUP_ALLOW_DIRTY=1 only for read-only local tests." >&2
  exit 1
fi

REPOSITORY="${LINEUP_GITHUB_REPOSITORY:-hcaiano/lineup}"
if [[ ! "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: LINEUP_GITHUB_REPOSITORY must be owner/name." >&2
  exit 1
fi

# Verify the repository is public before reading release metadata. A private fork must not leak
# its asset URL into a public appcast by accident.
VISIBILITY="$(gh api "repos/${REPOSITORY}" --jq '.visibility')"
[ "${VISIBILITY}" = "public" ] || {
  echo "error: GitHub repository ${REPOSITORY} is not public." >&2
  exit 1
}

if [ "${1:-}" = "--verify" ]; then
  TAG="${2:?usage: nightly-release.sh --verify vX.Y.Z-nightly.YYYYMMDD.sequence}"
  [[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[1-9][0-9]*$ ]] || {
    echo "error: tag must be vX.Y.Z-nightly.YYYYMMDD.sequence." >&2
    exit 1
  }
  if ! NIGHTLY_RELEASE_JSON="$(gh api "repos/${REPOSITORY}/releases/tags/${TAG}")"; then
    echo "error: could not read the exact GitHub release for ${TAG}." >&2
    exit 1
  fi
  export NIGHTLY_RELEASE_JSON
  export NIGHTLY_REPOSITORY="${REPOSITORY}" NIGHTLY_TAG="${TAG}"
  if ! TAG_REF_JSON="$(gh api "repos/${REPOSITORY}/git/ref/tags/${TAG}")"; then
    echo "error: could not resolve the Git tag ref for ${TAG}." >&2
    exit 1
  fi
  export TAG_REF_JSON
  TAG_OBJECT_TYPE="$(python3 - <<'PY'
import json
import os

try:
    obj = json.loads(os.environ["TAG_REF_JSON"])["object"]
    print(obj["type"])
except (KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit("error: GitHub returned an invalid tag ref.")
PY
)"
  TAG_OBJECT_SHA="$(python3 - <<'PY'
import json
import os

try:
    obj = json.loads(os.environ["TAG_REF_JSON"])["object"]
    print(obj["sha"])
except (KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit("error: GitHub returned an invalid tag ref.")
PY
)"
  TAG_DEPTH=0
  while [ "${TAG_OBJECT_TYPE}" = "tag" ]; do
    TAG_DEPTH=$((TAG_DEPTH + 1))
    if [ "${TAG_DEPTH}" -gt 8 ]; then
      echo "error: Git tag ${TAG} has too many annotated tag layers." >&2
      exit 1
    fi
    if ! TAG_OBJECT_JSON="$(gh api "repos/${REPOSITORY}/git/tags/${TAG_OBJECT_SHA}")"; then
      echo "error: could not peel annotated Git tag ${TAG_OBJECT_SHA}." >&2
      exit 1
    fi
    export TAG_OBJECT_JSON
    TAG_OBJECT_TYPE="$(TAG_JSON="${TAG_OBJECT_JSON}" python3 - <<'PY'
import json
import os

try:
    obj = json.loads(os.environ["TAG_JSON"])["object"]
    print(obj["type"])
except (KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit("error: GitHub returned an invalid annotated tag object.")
PY
)"
    TAG_OBJECT_SHA="$(TAG_JSON="${TAG_OBJECT_JSON}" python3 - <<'PY'
import json
import os

try:
    obj = json.loads(os.environ["TAG_JSON"])["object"]
    print(obj["sha"])
except (KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit("error: GitHub returned an invalid annotated tag object.")
PY
)"
  done
  if [ "${TAG_OBJECT_TYPE}" != "commit" ]; then
    echo "error: Git tag ${TAG} did not resolve to a commit (type ${TAG_OBJECT_TYPE})." >&2
    exit 1
  fi
  TAG_COMMIT_SHA="${TAG_OBJECT_SHA}"
  if [ "${TAG_COMMIT_SHA}" != "${SOURCE_SHA}" ]; then
    echo "error: Git tag ${TAG} resolves to ${TAG_COMMIT_SHA}, not local source ${SOURCE_SHA}." >&2
    exit 1
  fi
  export NIGHTLY_TAG_COMMIT_SHA="${TAG_COMMIT_SHA}"
  python3 - <<'PY'
import datetime
import json
import os
import re

tag = os.environ["NIGHTLY_TAG"]
release = json.loads(os.environ["NIGHTLY_RELEASE_JSON"])
if release.get("tag_name") != tag:
    raise SystemExit("error: GitHub returned release metadata for a different tag.")
if release.get("draft", False) or not release.get("prerelease", False):
    raise SystemExit("error: the exact GitHub release tag is not a public prerelease.")
if release.get("immutable") is not True:
    raise SystemExit("error: the exact GitHub release must be immutable (immutable=true).")
match = re.fullmatch(r"v(\d+\.\d+\.\d+)-nightly\.(\d{8})\.(\d+)", tag)
if not match:
    raise SystemExit("error: the exact GitHub release tag is not a Nightly tag.")
version = f"{match.group(1)}-nightly.{match.group(2)}.{match.group(3)}"
try:
    nightly_date = datetime.datetime.strptime(match.group(2), "%Y%m%d").date()
except ValueError:
    raise SystemExit("error: Nightly tag contains an invalid calendar date.")
offset = (nightly_date - datetime.date(2026, 1, 1)).days
if not 0 <= offset <= 9998:
    raise SystemExit("error: Nightly tag date is outside the supported 2026-2053 range.")
sequence = int(match.group(3))
if not 1 <= sequence <= 255:
    raise SystemExit("error: Nightly tag sequence must be from 1 through 255.")
asset_name = f"Lineup-{version}.dmg"
assets = [asset for asset in release.get("assets", []) if asset.get("name") == asset_name]
if len(assets) != 1:
    raise SystemExit(f"error: public prerelease {tag} has no unique {asset_name} asset.")
asset_url = assets[0].get("browser_download_url", "")
expected = f"https://github.com/{os.environ['NIGHTLY_REPOSITORY']}/releases/download/{tag}/{asset_name}"
if asset_url != expected:
    raise SystemExit("error: the prerelease asset URL is not the exact tag-addressed URL.")
print("channel=nightly")
print(f"repository={os.environ['NIGHTLY_REPOSITORY']}")
print(f"source_sha={os.environ['NIGHTLY_SOURCE_SHA']}")
print(f"tag={tag}")
print(f"immutable={str(release['immutable']).lower()}")
print(f"target_commitish={release.get('target_commitish', '')}")
print(f"tag_commit_sha={os.environ['NIGHTLY_TAG_COMMIT_SHA']}")
print(f"version={version}")
print(f"asset_name={asset_name}")
print(f"asset_url={asset_url}")
PY
  exit 0
fi

DATE="${LINEUP_NIGHTLY_DATE:-$(date -u +%Y%m%d)}"
[[ "${DATE}" =~ ^[0-9]{8}$ ]] || {
  echo "error: LINEUP_NIGHTLY_DATE must be YYYYMMDD." >&2
  exit 1
}
DATE="${DATE}" python3 - <<'PY'
import datetime
import os

try:
    datetime.datetime.strptime(os.environ["DATE"], "%Y%m%d")
except ValueError:
    raise SystemExit("error: LINEUP_NIGHTLY_DATE is not a real UTC calendar date.")
PY

RELEASES_JSON="$(gh api --paginate --slurp "repos/${REPOSITORY}/releases?per_page=100")"
export RELEASES_JSON
STABLE_VERSION="$(python3 - <<'PY'
import json
import os
import re

payload = json.loads(os.environ["RELEASES_JSON"])
releases = [release for page in payload for release in page] if payload and isinstance(payload[0], list) else payload
stable = []
for release in releases:
    tag = release.get("tag_name", "")
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
    if match and not release.get("draft", False) and not release.get("prerelease", False):
        stable.append(tuple(int(part) for part in match.groups()))
if not stable:
    raise SystemExit("error: no public stable vMAJOR.MINOR.PATCH release was found.")
stable.sort()
print(".".join(str(part) for part in stable[-1]))
PY
)"

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [ "${STABLE_VERSION}" != "${SOURCE_VERSION}" ]; then
  echo "error: latest public Stable ${STABLE_VERSION} does not match source Info.plist ${SOURCE_VERSION}." >&2
  echo "       Update the Stable source version before planning a Nightly." >&2
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<<"${STABLE_VERSION}"
NEXT_PATCH=$((PATCH + 1))
NEXT_VERSION="${MAJOR}.${MINOR}.${NEXT_PATCH}"
export NEXT_VERSION DATE

CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
[[ "${CURRENT_BUILD}" =~ ^[1-9][0-9]{0,3}$ ]] || {
  echo "error: source Stable CFBundleVersion must be one integer from 1 through 9999." >&2
  exit 1
}
if [ "${CURRENT_BUILD}" -ge 9999 ]; then
  echo "error: source Stable CFBundleVersion has no next integer build for Nightly ordering." >&2
  exit 1
fi

SEQUENCE="${LINEUP_NIGHTLY_SEQUENCE:-}"
if [ -z "${SEQUENCE}" ]; then
  SEQUENCE="$(python3 - <<'PY'
import json
import os
import re

prefix = f"v{os.environ['NEXT_VERSION']}-nightly.{os.environ['DATE']}."
release_pages = json.loads(os.environ["RELEASES_JSON"])
releases = [release for page in release_pages for release in page] if release_pages and isinstance(release_pages[0], list) else release_pages
sequences = []
for release in releases:
    tag = release.get("tag_name", "")
    match = re.fullmatch(re.escape(prefix) + r"(\d+)", tag)
    if match:
        sequences.append(int(match.group(1)))
print(max(sequences, default=0) + 1)
PY
  )"
fi
[[ "${SEQUENCE}" =~ ^[1-9][0-9]*$ ]] && [ "${SEQUENCE}" -le 255 ] || {
  echo "error: Nightly sequence must be an integer from 1 through 255." >&2
  exit 1
}

TAG="v${NEXT_VERSION}-nightly.${DATE}.${SEQUENCE}"
export TAG CURRENT_BUILD DATE SEQUENCE
python3 - <<'PY'
import datetime
import json
import os
import re

release_pages = json.loads(os.environ["RELEASES_JSON"])
releases = [release for page in release_pages for release in page] if release_pages and isinstance(release_pages[0], list) else release_pages
tag = os.environ["TAG"]
if any(release.get("tag_name") == tag for release in releases):
    raise SystemExit(f"error: public GitHub already has the planned tag {os.environ['TAG']}.")

match = re.fullmatch(r"v(\d+\.\d+\.\d+)-nightly\.(\d{8})\.(\d+)", tag)
if not match:
    raise SystemExit("error: generated Nightly tag has an invalid shape.")
candidate_date = datetime.datetime.strptime(match.group(2), "%Y%m%d").date()
candidate_sequence = int(match.group(3))
next_version = os.environ["NEXT_VERSION"]
pattern = re.compile(rf"v{re.escape(next_version)}-nightly\.(\d{{8}})\.(\d+)$")
reference = datetime.date(2026, 1, 1)
existing = []
for release in releases:
    if release.get("draft", False) or not release.get("prerelease", False):
        continue
    existing_match = pattern.fullmatch(release.get("tag_name", ""))
    if not existing_match:
        continue
    try:
        existing_date = datetime.datetime.strptime(existing_match.group(1), "%Y%m%d").date()
    except ValueError:
        raise SystemExit(f"error: public Nightly tag {release.get('tag_name', '')} has an invalid calendar date.")
    existing_offset = (existing_date - reference).days
    if not 0 <= existing_offset <= 9998:
        raise SystemExit(f"error: public Nightly tag {release.get('tag_name', '')} is outside the supported date range.")
    existing_sequence = int(existing_match.group(2))
    if not 1 <= existing_sequence <= 255:
        raise SystemExit(f"error: public Nightly tag {release.get('tag_name', '')} has an invalid sequence.")
    existing.append((existing_date, existing_sequence, release.get("tag_name", "")))

if existing:
    newest_date, newest_sequence, newest_tag = max(existing)
    if (candidate_date, candidate_sequence) <= (newest_date, newest_sequence):
        raise SystemExit(
            f"error: planned Nightly {tag} is not newer than public Nightly {newest_tag}."
        )

# The generated version has the current Stable build as its first component, packed UTC date
# components in the remaining numeric components, and an Apple `aN` suffix. With the next Stable
# represented by the next integer first component, this shape is strictly between both Stable
# versions under Sparkle's standard comparator. Keep the arithmetic bounded here so that a manual
# date cannot accidentally produce an invalid or out-of-range bundle version.
current_build = int(os.environ["CURRENT_BUILD"])
candidate_offset = (candidate_date - reference).days
ordinal = candidate_offset + 1
revision, fix = divmod(ordinal, 100)
if not 0 <= candidate_offset <= 9998:
    raise SystemExit("error: Nightly date is outside the supported 2026-2053 range.")
if not 0 <= revision <= 99 or not 0 <= fix <= 99:
    raise SystemExit("error: generated Nightly date components cannot fit the Apple version shape.")
candidate_bundle = f"{current_build}.{revision:02d}.{fix:02d}a{candidate_sequence:03d}"
if not re.fullmatch(r"[1-9][0-9]{0,3}\.[0-9]{2}\.[0-9]{2}a[0-9]{3}", candidate_bundle):
    raise SystemExit("error: generated Nightly bundle version is not Apple-valid.")
PY
BUNDLE_VERSION="$(python3 - <<'PY'
import datetime
import os

date = datetime.datetime.strptime(os.environ["DATE"], "%Y%m%d").date()
reference = datetime.date(2026, 1, 1)
offset = (date - reference).days
if not 0 <= offset <= 9998:
    raise SystemExit("error: Nightly date is outside the supported 2026-2053 range.")
stable_build = int(os.environ["CURRENT_BUILD"])
sequence = int(os.environ["SEQUENCE"])
# Number the first day as revision 1. Sparkle treats trailing zero components as equal, so a
# version such as 19.00.00 could compare as Stable 19 instead of a newer Nightly.
ordinal = offset + 1
print(f"{stable_build}.{ordinal // 100:02d}.{ordinal % 100:02d}a{sequence:03d}")
PY
)"
ASSET_NAME="Lineup-${NEXT_VERSION}-nightly.${DATE}.${SEQUENCE}.dmg"
ASSET_URL="https://github.com/${REPOSITORY}/releases/download/${TAG}/${ASSET_NAME}"

# Recheck the generated value before showing it. This mirrors the build script's gate and makes
# the helper's output independently auditable without opening the app or contacting GitHub again.
if [[ ! "${BUNDLE_VERSION}" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}(\.[0-9]{1,2})?)?((d|a|b|fc)[0-9]{1,3})?$ ]]; then
  echo "error: generated '${BUNDLE_VERSION}' is not an Apple-valid CFBundleVersion." >&2
  exit 1
fi
if [[ "${BUNDLE_VERSION}" =~ (d|a|b|fc)([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" -gt 255 ]; then
  echo "error: generated suffix number must be from 1 through 255." >&2
  exit 1
fi

cat <<EOF
channel=nightly
repository=${REPOSITORY}
source_sha=${SOURCE_SHA}
current_stable=${STABLE_VERSION}
stable_build=${CURRENT_BUILD}
next_patch=${NEXT_VERSION}
tag=${TAG}
version=${NEXT_VERSION}-nightly.${DATE}.${SEQUENCE}
bundle_version=${BUNDLE_VERSION}
asset_name=${ASSET_NAME}
asset_url=${ASSET_URL}
EOF
