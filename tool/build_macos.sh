#!/usr/bin/env bash
# Build the macOS app, renewing the provisioning profile first if it's gone or
# about to expire.
#
# Why this exists: the signing identity is a FREE Apple Developer account, and
# free-team provisioning profiles live exactly 7 days. When one lapses Xcode
# deletes it, and the next full rebuild dies with:
#
#   No profiles for 'com.venugopal.vault' were found ... Automatic signing is
#   disabled and unable to generate a profile.
#
# The renewal itself is just `xcodebuild -allowProvisioningUpdates`, which
# `flutter build macos` has no way to pass through. So: check the expiry, renew
# only when needed (the renew build is slow), then hand off to Flutter.
#
# Usage: ./tool/build_macos.sh [--release|--debug|--profile]
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.venugopal.vault"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
# Renew with a couple of days to spare rather than on the day it dies.
MIN_DAYS_LEFT=2

days_left() {
  local best=-1
  shopt -s nullglob
  for p in "$PROFILE_DIR"/*.provisionprofile; do
    local plist exp secs d
    plist=$(security cms -D -i "$p" 2>/dev/null) || continue
    grep -q "$BUNDLE_ID" <<<"$plist" || continue
    exp=$(plutil -extract ExpirationDate raw -o - - <<<"$plist" 2>/dev/null) || continue
    secs=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null) || continue
    d=$(( (secs - $(date +%s)) / 86400 ))
    (( d > best )) && best=$d
  done
  echo "$best"
}

LEFT=$(days_left)
if (( LEFT < MIN_DAYS_LEFT )); then
  if (( LEFT < 0 )); then
    echo "No provisioning profile for $BUNDLE_ID — requesting one..."
  else
    echo "Profile for $BUNDLE_ID expires in ${LEFT}d — renewing..."
  fi
  # This is the only step that can mint a profile; it needs the Apple ID in
  # Xcode's accounts to still be signed in. Everything else is plain Flutter.
  if ! xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
       -configuration Debug -allowProvisioningUpdates \
       -destination 'platform=macOS' build >/tmp/vault_provision.log 2>&1; then
    echo "Provisioning renewal FAILED. Last lines:" >&2
    tail -20 /tmp/vault_provision.log >&2
    echo >&2
    echo "If it complains about the account, open Xcode > Settings > Accounts" >&2
    echo "and re-enter the Apple ID password, then re-run this script." >&2
    exit 1
  fi
  echo "Profile renewed (valid ~7 days — free Apple accounts don't get longer)."
else
  echo "Profile for $BUNDLE_ID valid for ${LEFT} more days."
fi

exec flutter build macos "${@:---debug}"
