#!/usr/bin/env bash
# One-time: create the Sparkle EdDSA signing key for Lineup.
#
# The PRIVATE key is stored in your login Keychain and NEVER touches the repo. The PUBLIC key
# is printed — paste it into Resources/Info.plist under <key>SUPublicEDKey</key>. Re-running is
# safe: it won't overwrite an existing private key. To just reprint the public key, pass -p.
#
# Usage: ./Scripts/sparkle-keygen.sh        # create (or keep) the key, print the public key
#        ./Scripts/sparkle-keygen.sh -p      # print the existing public key only
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null 2>&1 || true
GEN="$(find .build/artifacts -type f -name generate_keys 2>/dev/null | head -1)"
[ -x "${GEN}" ] || { echo "error: generate_keys not found; run 'swift build' first." >&2; exit 1; }

echo "==> Sparkle generate_keys (private key -> login Keychain; public key below)"
exec "${GEN}" "$@"
