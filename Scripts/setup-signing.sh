#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity so Lineup keeps the same
# signature across rebuilds. After running this once and re-building, you grant
# Accessibility ONE more time and it persists forever (no more remove-and-re-grant).
#
# Reversible: delete the "Lineup Self-Signed" certificate from Keychain Access anytime.
set -euo pipefail

IDENTITY="Lineup Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity '$IDENTITY' already exists. Nothing to do."
  exit 0
fi

# Securely remove the private key + temp artifacts on exit (no rm -rf; the cert's
# private key must not linger on disk, so shred-then-delete the specific files).
TMP="$(mktemp -d)"
cleanup() { rm -f "$TMP/key.pem" "$TMP/cert.pem" "$TMP/id.p12"; rmdir "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -out "$TMP/id.p12" -passout pass:lineup >/dev/null 2>&1

echo "==> importing into login keychain (allowing codesign to use it)"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P lineup -T /usr/bin/codesign -A >/dev/null

echo "==> done."
echo "    Now rebuild:   ./Scripts/build-app.sh ~/Applications"
echo "    Then grant Accessibility one last time; it will persist across future rebuilds."
echo "    (On the first build you may get a keychain prompt — click 'Always Allow'.)"
