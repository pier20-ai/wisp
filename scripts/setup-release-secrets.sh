#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One-time setup for .github/workflows/release.yml: stores the signing, notarization and update keys
# as GitHub Actions secrets of the repository the update feed points at (BRAND_FEED_URL), and writes
# the update key's public half into scripts/brand.env. Run it yourself, in Terminal: it asks for
# passwords, and nothing it reads is printed or kept on disk.
#
# Usage: scripts/setup-release-secrets.sh <DeveloperID.p12> [--repo owner/name] [--skip-sparkle]
#
#   DeveloperID.p12  the "Developer ID Application" certificate with its private key, exported from
#                    Keychain Access (My Certificates → the identity → Export…, with a password).
#   The Sparkle key: generate_keys keeps it in this Mac's login keychain (made on first run, reused
#   after); keep that keychain backed up, since a lost key means existing installs can't update.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"

P12=""; REPO=""; SPARKLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --skip-sparkle) SPARKLE=0; shift ;;
    *) P12="$1"; shift ;;
  esac
done
[ -z "$REPO" ] && REPO="$(printf '%s' "$BRAND_FEED_URL" | sed -nE 's|https://github.com/([^/]+/[^/]+)/.*|\1|p')"
[ -n "$REPO" ] || { echo "no --repo, and BRAND_FEED_URL isn't a GitHub URL" >&2; exit 2; }
[ -f "$P12" ] || { echo "usage: $0 <DeveloperID.p12> [--repo owner/name]" >&2; exit 2; }
command -v gh >/dev/null || { echo "needs the GitHub CLI (gh), signed in with admin access to $REPO" >&2; exit 1; }
gh repo view "$REPO" >/dev/null || { echo "can't see $REPO with gh" >&2; exit 1; }
echo "Setting release secrets on $REPO"

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
ask() { local v; read -r -p "$1: " v; trim "$v"; }
ask_secret() { local v; read -r -s -p "$1: " v; echo >&2; trim "$v"; }

P12_PASSWORD="$(ask_secret "Password of $(basename "$P12")")"
# Check the password and that the .p12 holds a Developer ID Application identity.
openssl pkcs12 -in "$P12" -nokeys -passin fd:3 3<<<"$P12_PASSWORD" 2>/dev/null | grep -q "Developer ID Application" \
  || openssl pkcs12 -legacy -in "$P12" -nokeys -passin fd:3 3<<<"$P12_PASSWORD" 2>/dev/null | grep -q "Developer ID Application" \
  || { echo "that .p12 can't be opened with this password, or has no Developer ID Application certificate" >&2; exit 1; }
base64 -i "$P12" | gh secret set DEVELOPER_ID_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO"

echo "Notarization: the Apple ID of the developer account, its team ID, and an app-specific password"
echo "(appleid.apple.com → Sign-In and Security → App-Specific Passwords)."
ask "Apple ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO"
ask "Team ID" | gh secret set NOTARY_TEAM_ID --repo "$REPO"
ask_secret "App-specific password" | gh secret set NOTARY_PASSWORD --repo "$REPO"

if [ "$SPARKLE" = 1 ]; then
  BIN="$("$REPO_ROOT/scripts/fetch-sparkle.sh")/bin"
  "$BIN/generate_keys" >/dev/null   # makes the key in the login keychain, or reuses it (it may ask to allow access)
  PUB="$("$BIN/generate_keys" -p)"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  "$BIN/generate_keys" -x "$T/key" >/dev/null
  gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$T/key"
  sed -i '' -E "s|^BRAND_SPARKLE_PUBLIC_KEY=.*|BRAND_SPARKLE_PUBLIC_KEY=\"\${BRAND_SPARKLE_PUBLIC_KEY:-$PUB}\"|" "$REPO_ROOT/scripts/brand.env"
  echo "Update key: public half $PUB, now in scripts/brand.env (commit it)."
fi
echo "Done. Secrets on $REPO:"; gh secret list --repo "$REPO"
