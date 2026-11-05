#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build WispProbe.app (universal, signed ad-hoc): the test app for the host side of the end-to-end
# test (docs/testing.md "End-to-end input and freshness"). It needs no permissions, so an ad-hoc
# signature is fine and it can be rebuilt freely.
#
# Usage: scripts/bundle-probe.sh [--output <dir>]      (default dist/)
#
# On the host, in the GUI session: open WispProbe.app (its windows record what they receive to
# ~/Library/Logs/WispProbe/events.jsonl), then share one of its windows in Wisp.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
OUTPUT_DIR="$REPO_ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

APP="$OUTPUT_DIR/WispProbe.app"
ID="$BRAND_BUNDLE_ID.probe"
echo "[probe] building WispProbe (release, arm64 + x86_64)…"
( cd "$REPO_ROOT" && swift build -c release --product WispProbe --arch arm64 --arch x86_64 ) >/dev/null \
  || { echo "[probe] swift build failed (run it directly to see why)" >&2; exit 1; }
BIN_DIR="$(cd "$REPO_ROOT" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/WispProbe" "$APP/Contents/MacOS/WispProbe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WispProbe</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>WispProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BRAND_VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier "$ID" "$APP"
codesign --verify --strict "$APP"
echo "[probe] ✓ $APP (ad-hoc signed; needs no permissions)"
