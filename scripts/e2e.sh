#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The end-to-end input and freshness test (docs/testing.md "End-to-end input and freshness").
#
# Loopback (this Mac only, no permissions): starts `wisp send --synthetic` recording what its
# windows receive (WISP_INPUT_LOG), runs `wisp e2e 127.0.0.1` against it, then fails on any STALL
# or ERROR line the host logged.
#
#   scripts/e2e.sh                              # the scripted pass: every scenario in windows 1, 2, 3
#   scripts/e2e.sh --net uk                     # the same over an emulated ~150 ms, 1.5 % loss link
#   scripts/e2e.sh --soak 10 --net uk           # 10 minutes of random input across the 3 windows
#   scripts/e2e.sh --fault focus-hold           # the host raises windows and holds input as a real one does
#   scripts/e2e.sh -- --seed 42 -v              # anything after -- goes to `wisp e2e`
#   scripts/e2e.sh --out <dir>                  # results there instead of .build/e2e/<time>/
# A long soak belongs on a Mac nobody is using: scripts/soak.command.
#
# A real host (WispProbe.app open and shared there; see docs/testing.md):
#
#   scripts/e2e.sh --host <mac> --host-log-cmd "ssh <user>@<mac> cat Library/Logs/WispProbe/events.jsonl"
#
# Everything this test writes (logs, the input log, support files) is under .build/e2e/<time>/; it
# never touches the real clipboard (a private pasteboard), phantoms, socket or logs.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${WISP_BIN:-$REPO_ROOT/.build/release/wisp}"
HOST="127.0.0.1"
HOST_LOG_CMD=""
SOAK=""
NET=""
FAULT=""
OUT=""
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --host-log-cmd) HOST_LOG_CMD="$2"; shift 2 ;;
    --soak) SOAK="$2"; shift 2 ;;
    --net) NET="$2"; shift 2 ;;
    --fault) FAULT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) echo "unknown argument: $1 (see the header of $0)" >&2; exit 2 ;;
  esac
done

[ -x "$BIN" ] || { echo "no $BIN: run swift build -c release first (or set WISP_BIN)" >&2; exit 2; }

[ -n "$OUT" ] || OUT="$REPO_ROOT/.build/e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/logs" "$OUT/support"
export WISP_SUPPORT_DIR="$OUT/support" WISP_LOG_DIR="$OUT/logs" WISP_NO_ALERTS=1 WISP_NO_PROBE=1
export WISP_LOG_KEEP=10000 # keep every rotated log: a soak's rare event must stay explainable
export WISP_SOCKET="${TMPDIR:-/tmp}/wisp-e2e-$$.sock"
export WISP_PASTEBOARD="wisp-e2e-$$"

# The app's real defaults: nothing here should change them, but put them back whatever happens.
DOMAIN="$(. "$REPO_ROOT/scripts/brand.env" && echo "$BRAND_BUNDLE_ID")"
SAVED_HOST="$(defaults read "$DOMAIN" lastHost 2>/dev/null || true)"
SAVED_LABEL="$(defaults read "$DOMAIN" lastHostLabel 2>/dev/null || true)"
HOST_PID=""
cleanup() {
  [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null && wait "$HOST_PID" 2>/dev/null || true
  for k in lastHost lastHostLabel; do
    if [ "$k" = lastHost ]; then v="$SAVED_HOST"; else v="$SAVED_LABEL"; fi
    if [ -n "$v" ]; then defaults write "$DOMAIN" "$k" -string "$v"; else defaults delete "$DOMAIN" "$k" 2>/dev/null || true; fi
  done
  rm -f "$WISP_SOCKET"
}
trap cleanup EXIT

VIEW_ENV=()
case "$NET" in
  "") ;;
  uk) VIEW_ENV+=(WISP_NET_DELAY_MS=75 WISP_NET_JITTER_MS=8 WISP_NET_LOSS=1.5) ;;
  *) echo "--net takes: uk" >&2; exit 2 ;;
esac

ARGS=("$HOST")
[ -n "$SOAK" ] && ARGS+=(--soak "$SOAK")

if [ "$HOST" = "127.0.0.1" ]; then
  if lsof -nP -iTCP:7878 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "TCP 7878 is in use (a host is running): stop it first" >&2; exit 2
  fi
  INPUT="$OUT/input.jsonl"
  echo "host: wisp send --synthetic 1600x1000 (input log $INPUT${FAULT:+, WISP_FAULT=$FAULT})"
  env ${FAULT:+WISP_FAULT=$FAULT} WISP_INPUT_LOG="$INPUT" "$BIN" send --synthetic 1600x1000 >"$OUT/host.out" 2>&1 &
  HOST_PID=$!
  for _ in $(seq 50); do
    lsof -nP -iTCP:7878 -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.2
  done
  ARGS+=(--host-log "$INPUT" --windows 1,2,3)
else
  [ -n "$HOST_LOG_CMD" ] || { echo "--host <mac> needs --host-log-cmd \"ssh … cat …/events.jsonl\"" >&2; exit 2; }
  ARGS+=(--host-log-cmd "$HOST_LOG_CMD" --app WispProbe)
fi

echo "viewer: wisp e2e ${ARGS[*]} ${EXTRA[*]:-}${VIEW_ENV[*]:+ (${VIEW_ENV[*]})}"
set +e
env ${VIEW_ENV[@]+"${VIEW_ENV[@]}"} "$BIN" e2e "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee "$OUT/e2e.out"
STATUS=${PIPESTATUS[0]}
set -e

if [ -n "$HOST_PID" ]; then
  kill "$HOST_PID" 2>/dev/null || true
  wait "$HOST_PID" 2>/dev/null || true
  HOST_PID=""
  # The host's own STALL and ERROR lines (its pid's lines in cli.log).
  if grep -E "STALL|ERROR" "$OUT/logs/cli.log" | grep -v "e2e:" | grep -E "WARN .*STALL|ERROR" >"$OUT/problems.txt"; then
    echo "FAIL the logs have STALL or ERROR lines:"; sed 's/^/  /' "$OUT/problems.txt" | head -20
    STATUS=1
  fi
fi
echo "e2e: $( [ "$STATUS" = 0 ] && echo PASSED || echo FAILED ) (output in $OUT)"
exit "$STATUS"
