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
  echo "Signing identity '$IDENTITY' already works (stable, cert-based signature)."
  # The backup can only be regenerated from fresh key material, which a re-run doesn't have.
  # If a portable copy is wanted but missing, say so honestly instead of implying a re-run
  # would produce it — exporting the existing cert is the way to keep the SAME signature.
  if [ "${BACKUP_IDENTITY:-0}" = "1" ] && [ ! -f "$BACKUP_P12" ]; then
    echo "Note: a re-run can't recreate the backup .p12 (the private key only existed during"
    echo "      first setup). To get a portable copy WITHOUT changing the certificate (which"
    echo "      would cost users one more re-grant), export '$IDENTITY' from Keychain Access"
    echo "      (File > Export Items) as a .p12. Only delete + re-run if a new cert is acceptable."
  else
    echo "Nothing to do."
  fi
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

# PKCS#12 must be in a format the macOS Security framework can import, across both OpenSSL
# flavors a maintainer might have:
#   - OpenSSL 3.x defaults to a MAC/cipher macOS can't read; it needs `-legacy`. Without it,
#     `security import` fails ("MAC verification failed"), the key never lands, and codesign
#     silently falls back to ad-hoc. (That's why the old script never worked on OpenSSL 3.)
#   - LibreSSL (stock macOS /usr/bin/openssl) and OpenSSL 1.x have no `-legacy` flag and don't
#     need it — their default output already imports.
# So: try `-legacy`, fall back to plain `-export`. Whichever produces a usable identity is
# confirmed by the sign-probe verification later.
make_p12() { # $1 = output path
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$1" -passout "pass:$P12_PASS" >/dev/null 2>&1 && return 0
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$1" -passout "pass:$P12_PASS" >/dev/null 2>&1
}

make_p12 "$TMP/id.p12"
echo "==> importing into the login keychain"
# -T grants ONLY codesign access to the key. We deliberately omit -A (which would let any
# app use the key without a prompt) and instead authorize codesign precisely via
# set-key-partition-list below — least privilege for a signing key.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

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
  # Scope the partition-list change to OUR key (-l "$IDENTITY") so other keys in the login
  # keychain are left untouched.
  if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$IDENTITY" -k "$LOGIN_PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    authorized."
  else
    echo "    (couldn't set partition list — wrong password? You'll get one 'Always Allow' prompt on first build.)"
  fi
  unset LOGIN_PW
else
  echo "    skipped; expect one 'Always Allow' prompt on the first build."
fi

# Optionally keep a durable, reusable copy of the identity (same cert => same signature =>
# grant sticks across machines). Opt-in with BACKUP_IDENTITY=1, because the file is a usable
# signing key protected only by a fixed password — anyone who gets it can sign as Lineup and
# satisfy the TCC-granted requirement. Default off: the keychain copy is enough for one build
# machine, and losing it only costs users one extra re-grant.
if [ "${BACKUP_IDENTITY:-0}" = "1" ]; then
  mkdir -p "$BACKUP_DIR"
  make_p12 "$BACKUP_P12"
  chmod 600 "$BACKUP_P12"
  echo "==> backed up the signing identity to $BACKUP_P12 (SENSITIVE — keep it out of cloud sync/backups)"
fi

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
if [ "${BACKUP_IDENTITY:-0}" = "1" ]; then
  echo "  Backup identity:  $BACKUP_P12 (SENSITIVE) — reuse it on another build machine so"
  echo "                    every release shares one signature; never commit or sync it."
else
  echo "  Backup:           skipped. Re-run with BACKUP_IDENTITY=1 to export a reusable .p12"
  echo "                    (sensitive) if you'll build releases on more than one machine."
fi
echo "  Next:             ./Scripts/build-app.sh ~/Applications, then grant Accessibility one"
echo "                    last time. Future updates keep the grant."
