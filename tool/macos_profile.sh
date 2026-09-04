#!/usr/bin/env bash
# Ensure a usable macOS provisioning profile, renewing it if it's missing or
# nearly expired. Safe and fast to call before any macOS build or run.
#
# WHY THIS KEEPS HAPPENING: the signing identity is a FREE Apple Developer
# account, and free-team profiles are valid for ~7 days. When one lapses Xcode
# DELETES it, and the next build dies with:
#
#   No profiles for 'com.venugopal.vault' were found ... Automatic signing is
#   disabled and unable to generate a profile.
#
# Minting one needs `xcodebuild -allowProvisioningUpdates` — a flag neither
# `flutter build macos` nor `flutter run -d macos` can pass through. Hence this.
#
# Not switching to local signing ("Sign to Run Locally") on purpose: it would
# end the renewals, but ad-hoc signatures change on every build, and the app's
# session lives in the KEYCHAIN, whose ACLs are bound to the signing identity.
# You'd trade a weekly renewal for being logged out on every rebuild.
#
# Usage: ./tool/macos_profile.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.venugopal.vault"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
MIN_DAYS_LEFT=2   # renew with room to spare, not on the day it dies

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
if [ "${1:-}" != "--force" ] && (( LEFT >= MIN_DAYS_LEFT )); then
  echo "macOS profile valid for ${LEFT} more day(s)."
  exit 0
fi

if (( LEFT < 0 )); then
  echo "No macOS provisioning profile for $BUNDLE_ID — requesting one…"
else
  echo "macOS profile expires in ${LEFT} day(s) — renewing…"
fi

# The only step that can mint a profile. Needs the Apple ID in Xcode's accounts
# to still be signed in.
if ! xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
     -configuration Debug -allowProvisioningUpdates \
     -destination 'platform=macOS' build >/tmp/vault_provision.log 2>&1; then
  echo "Provisioning renewal FAILED. Last lines:" >&2
  tail -20 /tmp/vault_provision.log >&2
  echo >&2
  echo "If it mentions the account, open Xcode > Settings > Accounts, re-enter" >&2
  echo "the Apple ID password, then run this again." >&2
  exit 1
fi

echo "Renewed — valid ~7 days (free Apple accounts don't get longer)."
