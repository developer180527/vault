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

./tool/macos_profile.sh

exec flutter build macos "${@:---debug}"
