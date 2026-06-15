#!/usr/bin/env bash
# One-time: create a stable, self-signed code-signing identity so Lineup keeps the SAME
# code signature across rebuilds. macOS keys the Accessibility (TCC) grant to the app's
# code-signing requirement; an ad-hoc signature changes every build, so users have to
# remove + re-add Lineup in System Settings on every update. A reused self-signed cert
# gives a stable requirement (identifier + certificate leaf), so the grant persists: users
# authorize once and updates keep working.
#
# Run this ONCE on the machine that builds releases. Then build-app.sh signs with it
# automatically. Back up the exported .p12 (printed below) — if the identity is lost and
# regenerated, the certificate hash changes and users would have to re-authorize one more
# time.
#
# Reversible: delete the "Lineup Self-Signed" certificate from Keychain Access anytime.
set -euo pipefail

IDENTITY="Lineup Self-Signed"
BUNDLE_ID="com.caiano.lineup"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="lineup"
# Durable backup of the identity so the SAME cert can be re-imported on another machine
# (or after a keychain reset) without changing the signature. Lives under $HOME, outside
# the repo — never commit a signing key.
BACKUP_DIR="$HOME/.config/lineup/signing"
BACKUP_P12="$BACKUP_DIR/lineup-self-signed.p12"

# Verify by SIGNING a probe and inspecting the requirement — NOT via `find-identity`, which
# reports zero "valid" identities for an untrusted self-signed cert even though codesign can
# use it perfectly well.
identity_signs_with_stable_requirement() {
  local dir probe req
  dir="$(mktemp -d)"; probe="$dir/probe"
  if ! printf 'int main(){return 0;}' | cc -x c - -o "$probe" 2>/dev/null; then
    rmdir "$dir" 2>/dev/null || true; return 1
  fi
  if ! codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$probe" 2>/dev/null; then
    rm -f "$probe"; rmdir "$dir" 2>/dev/null || true; return 1
  fi
  req="$(codesign -d -r- "$probe" 2>&1 | grep designated || true)"
  rm -f "$probe"; rmdir "$dir" 2>/dev/null || true
  # Must be cert-based (stable), not a bare cdhash (ad-hoc).
  echo "$req" | grep -q 'certificate leaf'
}

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && identity_signs_with_stable_requirement; then
  echo "Signing identity '$IDENTITY' already works (stable, cert-based signature). Nothing to do."
  exit 0
fi

# Remove the private key + temp artifacts on exit (delete the specific files so the cert's
# private key does not linger; no rm -rf of arbitrary trees).
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

# CRITICAL: -legacy. OpenSSL 3.x defaults to a PKCS#12 MAC/cipher that the macOS Security
# framework cannot read, so `security import` fails ("MAC verification failed") and the key
# never lands — codesign then silently falls back to ad-hoc. -legacy emits a PKCS#12 macOS
# can import. (This is why the previous version of this script never actually worked on
# modern macOS + OpenSSL 3.)
make_p12() { # $1 = output path
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$1" -passout "pass:$P12_PASS" >/dev/null 2>&1
}

make_p12 "$TMP/id.p12"
echo "==> importing into the login keychain"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A >/dev/null

# Let codesign use the key without a GUI prompt on every build. This needs the login
# keychain password; if you skip it, macOS asks "codesign wants to use a key — Always
# Allow?" on the first build instead (click Always Allow once).
echo "==> authorizing codesign to use the key (avoids a prompt on every build)"
echo "    Enter your macOS LOGIN password for the keychain, or press Return to skip and"
echo "    click 'Always Allow' on the first build instead."
LOGIN_PW=""
read -r -s -p "    Login password (optional): " LOGIN_PW || true
echo
if [ -n "$LOGIN_PW" ]; then
  if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$LOGIN_PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    authorized."
  else
    echo "    (couldn't set partition list — wrong password? You'll get one 'Always Allow' prompt on first build.)"
  fi
  unset LOGIN_PW
else
  echo "    skipped; expect one 'Always Allow' prompt on the first build."
fi

# Keep a durable, reusable copy of the identity (same cert => same signature => grant sticks).
mkdir -p "$BACKUP_DIR"
make_p12 "$BACKUP_P12"
chmod 600 "$BACKUP_P12"

echo "==> verifying the identity produces a stable, cert-based signature"
if identity_signs_with_stable_requirement; then
  echo "    OK — Lineup will sign with a stable identity; Accessibility persists across updates."
else
  echo "ERROR: the identity imported but codesign did not produce a cert-based signature." >&2
  echo "       Builds would still fall back to ad-hoc. Check Keychain Access for '$IDENTITY'." >&2
  exit 1
fi

echo
echo "Done."
echo "  Backup identity:  $BACKUP_P12  (password: $P12_PASS) — keep it safe; reuse it on any"
echo "                    build machine so every release shares one signature."
echo "  Next:             ./Scripts/build-app.sh ~/Applications, then grant Accessibility one"
echo "                    last time. Future updates keep the grant."
