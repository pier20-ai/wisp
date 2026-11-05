#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One-time: create a self-signed code-signing identity named "<BRAND_NAME> Dev" (scripts/brand.env)
# in the login keychain. Builds signed with it keep a stable code identity, so macOS remembers the
# app's Screen Recording and Accessibility grants across rebuilds (ad-hoc signatures change with
# every build). It is only trusted on this Mac; it is not a substitute for a Developer ID.
# Run it in a GUI Terminal on the Mac (the login keychain is locked to SSH sessions).
#   scripts/make-dev-cert.sh [keychain]        default: the login keychain
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
# Uses macOS's own openssl (LibreSSL): a .p12 from Homebrew's OpenSSL 3 uses a cipher `security import` rejects.
NAME="$BRAND_DEV_CERT"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "\"$NAME\" already exists in $KEYCHAIN"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A throwaway password for the temporary .p12 only (it's deleted with $TMP).
P12PASS="$(/usr/bin/openssl rand -hex 16)"
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PASS" 2>/dev/null
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
echo "created code-signing identity \"$NAME\" in $KEYCHAIN"
echo "build with:  scripts/bundle-app.sh --identity \"$NAME\"   (scripts/host-build.command picks it up by itself)"
