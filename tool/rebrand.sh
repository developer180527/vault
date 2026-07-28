#!/usr/bin/env bash
# Point a fork of Vault at YOUR identifiers.
#
# The app's bundle id isn't just cosmetic: it doubles as the OAuth redirect
# scheme (`<bundle-id>://oauth`) that Pocket ID calls back to. It appears in
# five places across four platforms, and if any one of them drifts, login fails
# at the callback with an error that doesn't mention bundle ids at all. This
# script changes them together so that can't happen.
#
#   tool/rebrand.sh --bundle-id com.yourname.vault [--team ABCDE12345]
#
# After running: re-register the redirect URI in Pocket ID's OIDC client to
# match the new scheme, then rebuild.
set -euo pipefail

BUNDLE=""
TEAM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id) BUNDLE="${2:-}"; shift 2 ;;
    --team)      TEAM="${2:-}";   shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BUNDLE" ]; then
  echo "error: --bundle-id is required (e.g. com.yourname.vault)" >&2
  exit 2
fi
# Reverse-DNS, lowercase; Apple and Android both reject anything else, and an
# invalid id fails late and confusingly (at signing / at the OAuth callback).
if ! printf '%s' "$BUNDLE" | grep -Eq '^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$'; then
  echo "error: '$BUNDLE' is not a valid reverse-DNS id (want: com.example.vault)" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
say() { printf '  %s\n' "$1"; }

echo "Rebranding to $BUNDLE"

# 1. Dart: the OAuth redirect constant the client hands to the IdP.
perl -pi -e "s{const kOAuthRedirect = '[^']*://oauth';}{const kOAuthRedirect = '$BUNDLE://oauth';}" \
  lib/core/auth/session.dart
say "lib/core/auth/session.dart  (OAuth redirect)"

# 2/3. Apple bundle ids. The test targets carry a `.RunnerTests` suffix and
# must KEEP it — two targets sharing one bundle id is rejected at build time.
# So rewrite the suffixed ones first, then everything else (the lookahead stops
# the second pass from clobbering what the first just wrote).
rewrite_bundle_ids() {
  perl -pi -e \
    "s/PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9._-]+\.RunnerTests;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE.RunnerTests;/g" "$1"
  perl -pi -e \
    "s/PRODUCT_BUNDLE_IDENTIFIER = (?![A-Za-z0-9._-]*\.RunnerTests;)[A-Za-z0-9._-]+;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE;/g" "$1"
}
rewrite_bundle_ids ios/Runner.xcodeproj/project.pbxproj
rewrite_bundle_ids macos/Runner.xcodeproj/project.pbxproj
# The URL type AppAuth listens on for the OIDC callback — BOTH the name and
# the scheme. Keyed off the plist keys rather than position, so an unrelated
# edit to Info.plist can't silently retarget these.
perl -0pi -e "s{(<key>CFBundleURLName</key>\s*<string>)[^<]*(</string>)}{\${1}$BUNDLE\${2}}g" \
  ios/Runner/Info.plist
perl -0pi -e "s{(<key>CFBundleURLSchemes</key>\s*<array>\s*<string>)[^<]*(</string>)}{\${1}$BUNDLE\${2}}g" \
  ios/Runner/Info.plist
say "ios/  (bundle id + URL scheme)"

# macOS's Runner id lives in the shared xcconfig, not the pbxproj.
perl -pi -e "s/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE/" \
  macos/Runner/Configs/AppInfo.xcconfig
say "macos/  (bundle id)"

# 4. Android: applicationId, namespace, and the AppAuth redirect placeholder.
perl -pi -e "s/applicationId = \"[^\"]*\"/applicationId = \"$BUNDLE\"/; \
             s/namespace = \"[^\"]*\"/namespace = \"$BUNDLE\"/; \
             s/manifestPlaceholders\[\"appAuthRedirectScheme\"\] = \"[^\"]*\"/manifestPlaceholders[\"appAuthRedirectScheme\"] = \"$BUNDLE\"/; \
             s{[A-Za-z0-9._-]+://oauth}{$BUNDLE://oauth}g" \
  android/app/build.gradle.kts
say "android/app/build.gradle.kts"

# 5. Apple signing team (optional — omit to sign ad-hoc / pick in Xcode).
if [ -n "$TEAM" ]; then
  perl -pi -e "s/DEVELOPMENT_TEAM = [A-Z0-9]+;/DEVELOPMENT_TEAM = $TEAM;/g" \
    ios/Runner.xcodeproj/project.pbxproj macos/Runner.xcodeproj/project.pbxproj
  say "Apple DEVELOPMENT_TEAM -> $TEAM"
else
  echo
  echo "No --team given: Apple signing is unchanged. Open the Xcode project and"
  echo "pick your own team under Signing & Capabilities before building for a"
  echo "device (a free personal Apple ID is enough)."
fi

cat <<EOF

Done. Two things left, both outside this repo:

  1. In Pocket ID -> OIDC Clients -> your vault client, set the redirect URI to
       $BUNDLE://oauth
     Login fails at the callback until this matches.
  2. Rebuild:  flutter clean && flutter pub get && flutter run

EOF
