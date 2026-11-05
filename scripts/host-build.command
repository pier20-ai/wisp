#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and sign the app on the Mac that will run it, e.g. a headless host.
# Signs with, in order of preference:
#   1. $BRAND_SIGN_IDENTITY (environment, or scripts/brand.local.env), e.g. your Developer ID;
#   2. the self-signed "<BRAND_NAME> Dev" identity from scripts/make-dev-cert.sh, if this account has it;
#   3. ad-hoc (macOS permissions then reset on every rebuild).
# Set HOST_BUILD_PULL=1 to `git pull --ff-only` first (never prompts for credentials).
# Run it in the GUI session (double-click it, or `open scripts/host-build.command` over SSH):
# the login keychain holding the signing key is locked to SSH sessions.
# The log goes to ${TMPDIR:-/tmp}/<cli>-build-<user>.log too.
cd "$(dirname "$0")/.."
. scripts/brand.env
[ -f scripts/brand.local.env ] && . scripts/brand.local.env

ID="$BRAND_SIGN_IDENTITY"
if [ -n "$ID" ] && ! security find-identity -p codesigning | grep -qF "$ID"; then
  echo "BRAND_SIGN_IDENTITY \"$ID\" isn't in this account's keychain; falling back"
  ID=""
fi
if [ -z "$ID" ] && security find-identity -p codesigning | grep -qF "\"$BRAND_DEV_CERT\""; then
  ID="$BRAND_DEV_CERT"
fi
[ -n "$ID" ] || ID="-"

{
  if [ "${HOST_BUILD_PULL:-0}" = 1 ]; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" git pull --ff-only || echo "(could not pull; building the checkout as it is)"
  fi
  scripts/bundle-app.sh --identity "$ID"
  echo "BUILD-EXIT $?"
} 2>&1 | tee "${TMPDIR:-/tmp}/$BRAND_CLI-build-$USER.log"
