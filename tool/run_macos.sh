#!/usr/bin/env bash
# `flutter run -d macos`, but renew the provisioning profile first.
#
# Use this instead of `flutter run -d macos` directly. The free-account profile
# expires about weekly, and `flutter run` has no way to pass the
# -allowProvisioningUpdates flag that renews it — so the dev loop breaks with
# "No profiles for 'com.venugopal.vault' were found" every few days.
#
# Any extra arguments are forwarded to flutter run.
set -euo pipefail
cd "$(dirname "$0")/.."
./tool/macos_profile.sh
exec flutter run -d macos "$@"
