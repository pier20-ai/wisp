#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a release: the app signed with a Developer ID and notarized, a notarized DMG around it,
# both checked with Gatekeeper, plus a zip and SHA-256 checksums, all in dist/.
#
# Usage: scripts/release.sh --identity "Developer ID Application: …" --notary-profile <name> [--skip-notarize] [--draft]
#   --draft: then scripts/draft-release.sh (appcast, notes, a draft GitHub release; needs gh and the tag pushed)
#   (or BRAND_SIGN_IDENTITY / BRAND_NOTARY_PROFILE in the environment or scripts/brand.local.env)
#
# Run it in a GUI session (scripts/release.command, or Terminal on the Mac): the login keychain holding
# the signing key and the notarytool profile is locked to SSH sessions. The version is BRAND_VERSION
# in scripts/brand.env. Nothing is uploaded anywhere but Apple's notary service.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
. scripts/brand.env
[ -f scripts/brand.local.env ] && . scripts/brand.local.env

IDENTITY="${BRAND_SIGN_IDENTITY:-}"
PROFILE="${BRAND_NOTARY_PROFILE:-}"
NOTARIZE=1
DRAFT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --draft) DRAFT=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;35m[release]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[release] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

case "$IDENTITY" in "Developer ID Application"*) ;; *) fail "needs a \"Developer ID Application\" identity (--identity or BRAND_SIGN_IDENTITY)" ;; esac
[ "$NOTARIZE" = 0 ] || [ -n "$PROFILE" ] || fail "needs --notary-profile <name> (or BRAND_NOTARY_PROFILE), or --skip-notarize"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the working tree has uncommitted changes: release from a clean commit"

COMMIT="$(git rev-parse --short HEAD)"
log "$BRAND_NAME $BRAND_VERSION from $COMMIT"

N=(); [ "$NOTARIZE" = 1 ] && N=(--notarize --notary-profile "$PROFILE")
scripts/bundle-app.sh --identity "$IDENTITY" ${N[@]+"${N[@]}"}
scripts/make-dmg.sh "dist/$BRAND_NAME.app" --identity "$IDENTITY" ${N[@]+"${N[@]}"}

APP="dist/$BRAND_NAME.app"
DMG="dist/$BRAND_NAME-$BRAND_VERSION.dmg"
ZIP="dist/$BRAND_NAME-$BRAND_VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Gatekeeper checks…"
spctl -a -vvv "$APP" 2>&1 | sed 's/^/  /'
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'
if [ "$NOTARIZE" = 1 ]; then
  xcrun stapler validate "$APP" >/dev/null || fail "the app has no stapled ticket"
  xcrun stapler validate "$DMG" >/dev/null || fail "the DMG has no stapled ticket"
  log "✓ app and DMG notarized and stapled"
fi

( cd dist && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$BRAND_NAME-$BRAND_VERSION.sha256" )
log "artifacts:"
ls -la "$DMG" "$ZIP" "dist/$BRAND_NAME-$BRAND_VERSION.sha256" | sed 's/^/  /'
cat "dist/$BRAND_NAME-$BRAND_VERSION.sha256" | sed 's/^/  /'
log "PASS — $BRAND_NAME $BRAND_VERSION ($COMMIT)"
if [ "$DRAFT" = 1 ]; then
  [ "$NOTARIZE" = 1 ] || fail "--draft needs a notarized build"
  scripts/draft-release.sh
fi
