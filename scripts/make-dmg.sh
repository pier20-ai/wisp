#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Wrap a built (ideally notarized) app in a disk image: the app plus an
# Applications shortcut to drag it onto. Names come from scripts/brand.env.
#
# Usage: scripts/make-dmg.sh [path/to/<Name>.app] [--identity <name>] [--notarize] [--notary-profile <name>]
#
# --identity (or $BRAND_SIGN_IDENTITY) signs the DMG (skipped for ad-hoc).
# --notarize submits the DMG under --notary-profile or $BRAND_NOTARY_PROFILE (no default)
# and staples the ticket. The app inside should already be notarized
# (bundle-app.sh --notarize).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
[ -f "$REPO_ROOT/scripts/brand.local.env" ] && . "$REPO_ROOT/scripts/brand.local.env"

APP="$REPO_ROOT/dist/$BRAND_NAME.app"
IDENTITY="${BRAND_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${BRAND_NOTARY_PROFILE:-}"
NOTARIZE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done

log()  { printf '\033[1;34m[dmg]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[dmg] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$APP" ] || fail "no app at $APP (run scripts/bundle-app.sh first)"
[ "$NOTARIZE" = 0 ] || [ -n "$NOTARY_PROFILE" ] || fail "--notarize needs --notary-profile <name> or BRAND_NOTARY_PROFILE"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
DMG="$REPO_ROOT/dist/$BRAND_NAME-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/$BRAND_CLI-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

log "staging $BRAND_NAME ${VERSION}…"
cp -R "$APP" "$STAGE/$BRAND_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -srcfolder "$STAGE" -volname "$BRAND_NAME" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG" \
  || fail "hdiutil create failed"

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  log "signing the DMG…"
  case "$IDENTITY" in
    "Developer ID Application"*) TIMESTAMP="--timestamp" ;;
    *)                           TIMESTAMP="--timestamp=none" ;;
  esac
  codesign --force --sign "$IDENTITY" "$TIMESTAMP" "$DMG" || fail "could not sign the DMG"
fi

if [ "$NOTARIZE" = 1 ]; then
  log "notarizing with profile \"$NOTARY_PROFILE\" (this can take a few minutes)…"
  NOTARY_KEYCHAIN=(); [ -n "${BRAND_NOTARY_KEYCHAIN:-}" ] && NOTARY_KEYCHAIN=(--keychain "$BRAND_NOTARY_KEYCHAIN")
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN[@]+"${NOTARY_KEYCHAIN[@]}"} --wait || fail "notarization failed"
  xcrun stapler staple "$DMG" || fail "stapling failed"
fi

log "PASS — $DMG"
