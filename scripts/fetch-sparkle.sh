#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch the pinned Sparkle release (https://sparkle-project.org, MIT) into .build/sparkle/<version>
# and print that directory. The archive's SHA-256 is checked against scripts/brand.env. It holds
# Sparkle.framework (embedded in release builds by bundle-app.sh) and bin/ (generate_keys,
# sign_update), used by scripts/make-appcast.sh and scripts/setup-release-secrets.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
DIR="$REPO_ROOT/.build/sparkle/$SPARKLE_VERSION"
if [ ! -d "$DIR/Sparkle.framework" ]; then
  T="$(mktemp -d)"
  URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "[sparkle] fetching $URL" >&2
  curl -fsSL -o "$T/sparkle.tar.xz" "$URL"
  echo "$SPARKLE_SHA256  $T/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null \
    || { echo "[sparkle] FAIL: SHA-256 mismatch for Sparkle $SPARKLE_VERSION" >&2; exit 1; }
  mkdir -p "$T/x" && tar -xf "$T/sparkle.tar.xz" -C "$T/x"
  rm -rf "$DIR" && mkdir -p "$(dirname "$DIR")" && mv "$T/x" "$DIR" && rm -rf "$T"
fi
echo "$DIR"
