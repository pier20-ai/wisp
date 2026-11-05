#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The end-to-end soak, all on one Mac (meant for one nobody is using, e.g. the Mac mini): builds if
# needed, then over loopback runs the synthetic host (recording what its windows receive) and the
# viewer (`wisp e2e`, real viewer windows on this screen) through the emulated UK link
# (75 ms each way, 8 ms jitter, 1.5 % loss): first the scripted pass, then <minutes> of random input
# across three windows. No permissions needed.
#
#   open scripts/soak.command                     # double-click in Finder works too: 30 minutes
#   scripts/soak.command 60                       # in a Terminal in the GUI session: 60 minutes
#   scripts/soak.command 20 none                  # without the link emulation
#   scripts/soak.command 20 uk focus-hold         # and the host raising windows as a real one does
#
# Everything goes to soak-results/<time>/ in the repository (untracked): summary.txt (ends with a
# PASS or FAIL line), scripted/ and soak/ (each: e2e.out, input.jsonl, logs/). Isolated like the
# other tests: a private pasteboard, its own log and support directories, the app's real defaults
# put back. Stop Wisp's sharing on this Mac first (the test host needs TCP 7878 / UDP 7879), and
# leave the Mac alone while it runs: its windows come to the front.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
MINUTES="${1:-30}"
NET="${2:-uk}"
FAULT="${3:-}"
OUT="$REPO_ROOT/soak-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "Wisp soak on $(scutil --get ComputerName 2>/dev/null || hostname), $(date): $MINUTES min, net ${NET}${FAULT:+, fault $FAULT}"
say "commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')$(git diff --quiet 2>/dev/null || echo ' (with local changes)')"

echo "building…"
if ! swift build -c release >"$OUT/build.log" 2>&1; then
  say "build failed: see $OUT/build.log"
  say "FAIL"
  exit 1
fi

if lsof -nP -iTCP:7878 -sTCP:LISTEN >/dev/null 2>&1; then
  say "TCP 7878 is in use (is Wisp sharing this Mac? Stop sharing first): $(lsof -nP -iTCP:7878 -sTCP:LISTEN | tail -1)"
  say "FAIL"
  exit 1
fi

NETARGS=()
[ "$NET" = "none" ] || NETARGS=(--net "$NET")
FAULTARGS=()
[ -n "$FAULT" ] && FAULTARGS=(--fault "$FAULT")

STATUS=0
run() { # name, args…
  local name="$1"; shift
  scripts/e2e.sh --out "$OUT/$name" "$@" >"$OUT/$name.out" 2>&1
  local s=$?
  grep -E "^FAIL|^warn" "$OUT/$name.out" | head -40 >>"$SUMMARY"
  say "$name: $(grep -E '^e2e (PASSED|FAILED)' "$OUT/$name.out" | tail -1 || echo "no result (see $name.out)")"
  [ "$s" = 0 ] || STATUS=1
}

run scripted ${NETARGS[@]+"${NETARGS[@]}"} ${FAULTARGS[@]+"${FAULTARGS[@]}"}
run soak ${NETARGS[@]+"${NETARGS[@]}"} ${FAULTARGS[@]+"${FAULTARGS[@]}"} --soak "$MINUTES"

say "results: $OUT"
if [ "$STATUS" = 0 ]; then say "PASS"; else say "FAIL"; fi
exit "$STATUS"
