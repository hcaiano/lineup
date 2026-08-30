#!/usr/bin/env bash
# The local half of the hybrid release: after the Release workflow has built, notarized,
# and published a GitHub release for vX.Y.Z, run this on a trusted Mac to ship the update.
#
# It downloads the EXACT notarized DMG the workflow released (the appcast signature must
# cover the bytes users actually download — a local rebuild would differ), EdDSA-signs the
# appcast with the Sparkle key in your login Keychain, and opens a PR with the feed and hosted DMG.
# After that PR merges, deploy web/ manually to prompt users to update.
#
# Why this stays local: the Sparkle EdDSA private key is the auto-update root of trust, so
# it is deliberately kept out of CI secrets. This is the only step that needs it.
#
# Usage: ./Scripts/publish-appcast.sh <version>        # e.g. 1.8.1
# Requires: gh (authed), the Sparkle private key in the login Keychain (Scripts/sparkle-keygen.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish-appcast.sh <version>   e.g. 1.8.1}"
TAG="v${VERSION}"
DMG="dist/Lineup-${VERSION}.dmg"
HOSTED_DMG="web/downloads/Lineup-${VERSION}.dmg"
BRANCH="appcast/${VERSION}"

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 || {
  echo "error: no GitHub release $TAG — push the $TAG tag and let the Release workflow finish first." >&2
  exit 1
}

echo "==> downloading the notarized DMG from release $TAG"
mkdir -p dist
gh release download "$TAG" --pattern "Lineup-${VERSION}.dmg" --dir dist --clobber
[ -f "$DMG" ] || { echo "error: $DMG not found after download" >&2; exit 1; }

# sparkle-appcast.sh fails closed unless the DMG is Developer ID-signed, notarized, and
# stapled — so it double-checks that CI really produced a shippable artifact before signing.
echo "==> signing appcast for $VERSION"
./Scripts/sparkle-appcast.sh "$DMG" "$VERSION"

if git diff --quiet -- web/appcast.xml \
  && git ls-files --error-unmatch "$HOSTED_DMG" >/dev/null 2>&1 \
  && git diff --quiet -- "$HOSTED_DMG"; then
  echo "==> web/appcast.xml already matches this release; nothing to publish."
  exit 0
fi

echo "==> opening appcast PR on $BRANCH"
git fetch origin main --quiet
git switch -c "$BRANCH" origin/main 2>/dev/null || git switch "$BRANCH"
# Re-run against the fresh branch so the change lands here regardless of the starting branch.
./Scripts/sparkle-appcast.sh "$DMG" "$VERSION"
git add -- web/appcast.xml "$HOSTED_DMG"
git commit -q -m "chore(appcast): publish ${VERSION} feed"
git push -u origin "$BRANCH" --quiet
gh pr create --base main --head "$BRANCH" \
  --title "chore(appcast): publish ${VERSION} feed" \
  --body "EdDSA-signed appcast and hosted copy of the notarized [${TAG}](../../releases/tag/${TAG}) DMG. Merge this PR, then deploy web/ to publish the update feed."

echo "==> done. Merge the PR, then deploy web/ to ship ${VERSION} to users."
