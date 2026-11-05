#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Write the Sparkle appcast for a release: one item for the notarized zip, signed with the update
# key (EdDSA), with that version's CHANGELOG.md section as its release notes. The release workflow
# attaches the result to the GitHub release as appcast.xml, which is what the app's feed URL
# (BRAND_FEED_URL: .../releases/latest/download/appcast.xml) resolves to once it is published.
#
# Usage: scripts/make-appcast.sh <app.zip> <download-url> [output, default dist/appcast.xml]
# The private key: $SPARKLE_PRIVATE_KEY (base64, as generate_keys -x writes it), else
# $SPARKLE_KEY_FILE, else the login keychain (where generate_keys keeps it).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/brand.env"
ZIP="$1"; URL="$2"; OUT="${3:-$REPO_ROOT/dist/appcast.xml}"
SPARKLE_DIR="$("$REPO_ROOT/scripts/fetch-sparkle.sh")"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
D="$T/app"; mkdir "$D"; ditto -x -k "$ZIP" "$D"
PLIST="$(ls -d "$D"/*.app)/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST" >/dev/null 2>&1 \
  || { echo "[appcast] FAIL: $ZIP has no SUPublicEDKey: it was built without updates" >&2; exit 1; }

KEY=()
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  (umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$T/key"); KEY=(--ed-key-file "$T/key")
elif [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
SIG="$("$SPARKLE_DIR/bin/sign_update" ${KEY[@]+"${KEY[@]}"} "$ZIP")"   # sparkle:edSignature="…" length="…"

python3 - "$REPO_ROOT/CHANGELOG.md" "$SHORT" "$BUILD" "$MINOS" "$URL" "$SIG" "$BRAND_NAME" "$OUT" <<'PY'
import html, re, sys
changelog, short, build, minos, url, sig, name, out = sys.argv[1:]
# The CHANGELOG section for this version, as simple HTML: paragraphs, bullet lists, **bold**, `code`.
text = open(changelog, encoding="utf-8").read()
m = re.search(r"^## " + re.escape(short) + r"\b.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
body = m.group(1).strip() if m else ""
def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", s)
blocks, items, para = [], [], []
def flush():
    global items, para
    if para: blocks.append("<p>" + inline(" ".join(para)) + "</p>"); para = []
    if items: blocks.append("<ul>" + "".join("<li>" + inline(i) + "</li>" for i in items) + "</ul>"); items = []
for line in body.splitlines():
    if line.startswith("- "): 
        if para: flush()
        items.append(line[2:].strip())
    elif line.startswith("  ") and items: items[-1] += " " + line.strip()
    elif not line.strip(): flush()
    else:
        if items: flush()
        para.append(line.strip())
flush()
notes = "\n".join(blocks) or "<p>See the release on GitHub.</p>"
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{html.escape(name)}</title>
    <item>
      <title>{html.escape(name)} {html.escape(short)}</title>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(short)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(minos)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {sig.strip()} />
    </item>
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(xml)
print(f"[appcast] wrote {out}: {name} {short} ({build})")
PY
