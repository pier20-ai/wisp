#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# After scripts/release.sh: write the signed Sparkle appcast and the release notes, and create a DRAFT
# GitHub release v<version> with the DMG, zip, checksums and appcast.xml. Publishing the draft (by
# hand, after a look) is what ships it: the feed is releases/latest/download/appcast.xml, and drafts
# are never "latest". Used by .github/workflows/release.yml and by `scripts/release.sh --draft`.
#
# The repository is the one in BRAND_FEED_URL; the tag v<version> must already be pushed there. The
# update key: $SPARKLE_PRIVATE_KEY, $SPARKLE_KEY_FILE, or the login keychain (see make-appcast.sh).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
. scripts/brand.env
V="$BRAND_VERSION"; TAG="v$V"
REPO="$(printf '%s' "$BRAND_FEED_URL" | sed -nE 's|https://github.com/([^/]+/[^/]+)/.*|\1|p')"
[ -n "$REPO" ] || { echo "[draft] FAIL: BRAND_FEED_URL isn't a GitHub releases URL" >&2; exit 1; }
for f in "dist/$BRAND_NAME-$V.dmg" "dist/$BRAND_NAME-$V.zip" "dist/$BRAND_NAME-$V.sha256"; do
  [ -f "$f" ] || { echo "[draft] FAIL: no $f (run scripts/release.sh first)" >&2; exit 1; }
done
grep -q "^## $V " CHANGELOG.md || { echo "[draft] FAIL: CHANGELOG.md has no '## $V' section" >&2; exit 1; }

scripts/make-appcast.sh "dist/$BRAND_NAME-$V.zip" \
  "https://github.com/$REPO/releases/download/$TAG/$BRAND_NAME-$V.zip" dist/appcast.xml
{
  awk -v v="$V" '$0 ~ "^## " v " " {on=1; next} /^## / {on=0} on' CHANGELOG.md
  echo
  echo "**Install:** download \`$BRAND_NAME-$V.dmg\`, open it and drag $BRAND_NAME to Applications. Signed and notarized."
  echo "Already have $BRAND_NAME? It updates itself (or: Check for Updates… in its menu)."
  echo
  echo '**SHA-256**'
  echo '```'
  cat "dist/$BRAND_NAME-$V.sha256"
  echo '```'
} > dist/release-notes.md
gh release create "$TAG" --repo "$REPO" --draft --verify-tag --title "$BRAND_NAME $V" --notes-file dist/release-notes.md \
  "dist/$BRAND_NAME-$V.dmg" "dist/$BRAND_NAME-$V.zip" "dist/$BRAND_NAME-$V.sha256" dist/appcast.xml
echo "[draft] PASS: draft release $TAG on $REPO (publish it to ship)"
