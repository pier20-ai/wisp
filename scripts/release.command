#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Double-click (or `open scripts/release.command` over SSH) to run scripts/release.sh in this GUI
# session, where the signing keychain is unlocked. Configure the identity and notary profile in
# scripts/brand.local.env (BRAND_SIGN_IDENTITY, BRAND_NOTARY_PROFILE). Optionally pulls first with
# RELEASE_PULL=1. The log also goes to $TMPDIR/<cli>-release-<user>.log, ending in RELEASE-EXIT <code>.
cd "$(dirname "$0")/.."
. scripts/brand.env
LOG="${TMPDIR:-/tmp}/$BRAND_CLI-release-$USER.log"
{
  if [ "${RELEASE_PULL:-0}" = 1 ]; then GIT_TERMINAL_PROMPT=0 git pull --ff-only origin main || { echo "pull failed"; echo "RELEASE-EXIT 1"; exit 1; }; fi
  scripts/release.sh
  echo "RELEASE-EXIT $?"
} 2>&1 | tee "$LOG"
