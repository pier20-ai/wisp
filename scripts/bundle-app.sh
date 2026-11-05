#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the app bundle (universal), signed so macOS runs it and TCC remembers it.
# Names and the bundle ID come from scripts/brand.env.
#
# Usage:
#   scripts/bundle-app.sh [--debug] [--output <dir>] [--identity <name>] [--notarize] [--notary-profile <name>]
#                         [--updates | --no-updates]
#
# --identity (or $BRAND_SIGN_IDENTITY): a stable identity matters. TCC keys its
#   grants (Screen Recording, Accessibility) to the code signature, and an
#   ad-hoc signature ("-", the default here) is just a hash of the binary, so
#   every rebuild is a new app and the grants must be given again. Pass a
#   Developer ID, or the self-signed identity from scripts/make-dev-cert.sh, to keep them.
#
# --notarize submits the app to Apple and staples the ticket. It needs a
#   "Developer ID Application" identity and a notarytool keychain profile:
#   --notary-profile <name> or $BRAND_NOTARY_PROFILE (there is no default; create one with
#   `xcrun notarytool store-credentials`). Do this BEFORE make-dmg.sh --notarize:
#   the app dragged out of the disk image needs its own ticket.
#
# Updates: Developer ID builds embed Sparkle.framework (scripts/fetch-sparkle.sh) and put the feed
#   and public key from brand.env in Info.plist, when BRAND_SPARKLE_PUBLIC_KEY is set. --updates
#   does it for any identity (to test), --no-updates never.
#
# $BRAND_NOTARY_KEYCHAIN: the keychain holding the notarytool profile, when it isn't the login
#   keychain (the release workflow makes a temporary one).
#
# The app's binary is also the CLI: <Name>.app/Contents/MacOS/<Name> send|view …

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
[ -f "$REPO_ROOT/scripts/brand.local.env" ] && . "$REPO_ROOT/scripts/brand.local.env"

CONFIGURATION="release"
OUTPUT_DIR="$REPO_ROOT/dist"
IDENTITY="${BRAND_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${BRAND_NOTARY_PROFILE:-}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
NOTARIZE=0
UPDATES=auto

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug"; shift ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --updates) UPDATES=1; shift ;;
    --no-updates) UPDATES=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

APP="$OUTPUT_DIR/$BRAND_NAME.app"
CONTENTS="$APP/Contents"

log()  { printf '\033[1;34m[bundle]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[bundle] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Brand check -------------------------------------------------------------

# The code's copy of the names (Sources/WispCommon/Brand.swift) must match brand.env, or the app
# would look for its defaults, logs and phantoms under a different name than its bundle has.
BRAND_SWIFT="$REPO_ROOT/Sources/WispCommon/Brand.swift"
swift_brand() { sed -nE "s/^ *public static let $1 = \"([^\"]*)\".*/\\1/p" "$BRAND_SWIFT"; }
[ "$(swift_brand name)" = "$BRAND_NAME" ] && [ "$(swift_brand cli)" = "$BRAND_CLI" ] && [ "$(swift_brand bundleID)" = "$BRAND_BUNDLE_ID" ] \
  || fail "scripts/brand.env and Sources/WispCommon/Brand.swift disagree (name/cli/bundleID): change both"

if [ "$NOTARIZE" = 1 ]; then
  case "$IDENTITY" in
    "Developer ID Application"*) ;;
    *) fail "--notarize needs a \"Developer ID Application\" identity (signing as: $IDENTITY)" ;;
  esac
  [ -n "$NOTARY_PROFILE" ] || fail "--notarize needs a notarytool profile: --notary-profile <name> or BRAND_NOTARY_PROFILE"
fi

# --- Signing identity -------------------------------------------------------

if [ "$IDENTITY" = "-" ]; then
  log "signing ad-hoc: Screen Recording / Accessibility grants will reset on every rebuild"
elif ! security find-identity -p codesigning | grep -qF "$IDENTITY"; then # no -v: a self-signed identity is untrusted but fine
  fail "no code-signing identity named \"$IDENTITY\" (security find-identity -p codesigning)"
else
  log "signing as: $IDENTITY"
fi

if [ "$UPDATES" = auto ]; then
  case "$IDENTITY" in "Developer ID Application"*) UPDATES=1 ;; *) UPDATES=0 ;; esac
  if [ "$UPDATES" = 1 ] && [ -z "$BRAND_SPARKLE_PUBLIC_KEY" ]; then
    log "no BRAND_SPARKLE_PUBLIC_KEY in brand.env: building without updates"
    UPDATES=0
  fi
fi
if [ "$UPDATES" = 1 ]; then
  [ -n "$BRAND_SPARKLE_PUBLIC_KEY" ] && [ -n "$BRAND_FEED_URL" ] || fail "--updates needs BRAND_FEED_URL and BRAND_SPARKLE_PUBLIC_KEY"
  SPARKLE_DIR="$("$REPO_ROOT/scripts/fetch-sparkle.sh")" || fail "could not fetch Sparkle"
  log "updates: Sparkle $SPARKLE_VERSION, feed $BRAND_FEED_URL"
fi
NOTARY_KEYCHAIN=(); [ -n "${BRAND_NOTARY_KEYCHAIN:-}" ] && NOTARY_KEYCHAIN=(--keychain "$BRAND_NOTARY_KEYCHAIN")

# --- Build ------------------------------------------------------------------

log "building ($CONFIGURATION, arm64 + x86_64)…"
BUILD_LOG="$(mktemp)"
if ! ( cd "$REPO_ROOT" && swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 ) >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | sort -u | head -40 >&2 || true
  tail -20 "$BUILD_LOG" >&2
  fail "swift build failed (above: its errors)"
fi
rm -f "$BUILD_LOG"
BIN_DIR="$(cd "$REPO_ROOT" && swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
# The SwiftPM executable target is "wisp" whatever the brand; it's renamed inside the bundle.
[ -x "$BIN_DIR/wisp" ] || fail "no binary at $BIN_DIR/wisp"

# --- Assemble ---------------------------------------------------------------

log "assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/wisp" "$CONTENTS/MacOS/$BRAND_NAME"
cp "$REPO_ROOT/scripts/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$BRAND_NAME</string>
  <key>CFBundleDisplayName</key><string>$BRAND_NAME</string>
  <key>CFBundleIdentifier</key><string>$BRAND_BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$BRAND_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BRAND_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>$BRAND_COPYRIGHT</string>
</dict>
</plist>
PLIST

if [ "$UPDATES" = 1 ]; then
  # Sparkle's XPC services are only for sandboxed apps; Wisp isn't one, so they're left out.
  mkdir -p "$CONTENTS/Frameworks"
  ditto "$SPARKLE_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
  rm -rf "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$CONTENTS/Frameworks/Sparkle.framework/XPCServices"
  P="$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $BRAND_FEED_URL" \
    -c "Add :SUPublicEDKey string $BRAND_SPARKLE_PUBLIC_KEY" \
    -c "Add :SUEnableAutomaticChecks bool true" \
    -c "Add :SUScheduledCheckInterval integer 86400" "$P" || fail "could not add the update keys to Info.plist"
fi

# --- Sign -------------------------------------------------------------------

# Notarization requires a secure timestamp, which Apple only issues for its own identities.
case "$IDENTITY" in
  "Developer ID Application"*) TIMESTAMP="--timestamp" ;;
  *)                           TIMESTAMP="--timestamp=none" ;;
esac

# The hardened runtime's library validation only loads a framework signed by the app's own team, which
# ad-hoc and self-signed identities don't have: test builds with updates go without it.
RUNTIME=(--options runtime)
if [ "$UPDATES" = 1 ] && [[ "$IDENTITY" != "Developer ID Application"* ]]; then
  log "updates in a non-Developer ID build: signing without the hardened runtime"
  RUNTIME=()
fi

log "signing…"
if [ "$UPDATES" = 1 ]; then
  # Inside out: Sparkle's helpers, then the framework, then the app (no --deep).
  SPK="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
  for item in "$SPK/Autoupdate" "$SPK/Updater.app" "$CONTENTS/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$TIMESTAMP" "$item" || fail "could not sign $item"
  done
fi
codesign --force --sign "$IDENTITY" --identifier "$BRAND_BUNDLE_ID" ${RUNTIME[@]+"${RUNTIME[@]}"} "$TIMESTAMP" "$APP" \
  || fail "could not sign the app"
codesign --verify --deep --strict "$APP" || fail "signature verification failed"
log "✓ signature verifies"

# --- Notarize (optional) ----------------------------------------------------

if [ "$NOTARIZE" = 1 ]; then
  ZIP="$OUTPUT_DIR/$BRAND_NAME-$BRAND_VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP" || fail "could not zip the app for notarization"
  log "notarizing the app with profile \"$NOTARY_PROFILE\" (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN[@]+"${NOTARY_KEYCHAIN[@]}"} --wait \
    || fail "notarization failed (xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE)"
  xcrun stapler staple "$APP" || fail "stapling failed"
  rm -f "$ZIP"
  log "✓ notarized and stapled"
fi

log "PASS — $APP"
log "run it:  open '$APP'"
log "CLI:     '$CONTENTS/MacOS/$BRAND_NAME' send --list"
