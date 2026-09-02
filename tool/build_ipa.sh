#!/usr/bin/env bash
# Build a sideloadable (unsigned) IPA for SideStore/AltStore.
#
# Two things here are NOT optional, both learned from a real install failure:
#
# 1. THIN THE FAT BINARIES. Flutter's App.framework and some plugin frameworks
#    ship as "Mach-O universal binary with 1 architecture" — a fat container
#    wrapping a single arm64 slice. In a fat container the slice starts at a
#    non-zero file offset, and ldid (which SideStore signs with) computes
#    signature placement against file-absolute offsets. The result is:
#
#        ldid.cpp(1461): _assert(): end >= size - 0x10
#
#    and the install fails. Thinning drops the wrapper; the code is identical.
#
# 2. AD-HOC SIGN EVERYTHING afterwards. A binary with no LC_CODE_SIGNATURE
#    forces the signer to INSERT a load command and grow __LINKEDIT; with one
#    present it only has to REPLACE a blob, which is the better-trodden path.
#
# Usage: ./tool/build_ipa.sh   → build/Vault.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ios/iphoneos/Runner.app
OUT=build/Vault.ipa

echo "==> Building unsigned release"
flutter build ios --release --no-codesign

echo "==> Thinning fat binaries to arm64"
find "$APP" -type f | while read -r f; do
  file -b "$f" 2>/dev/null | grep -q "^Mach-O universal" || continue
  echo "    thinning $(basename "$f")"
  lipo "$f" -thin arm64 -output "$f.thin"
  mv "$f.thin" "$f"
done

echo "==> Staging Payload"
rm -rf build/ipa "$OUT"
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
find build/ipa -name '.DS_Store' -delete
xattr -cr build/ipa/Payload/Runner.app

echo "==> Ad-hoc signing (frameworks inner-out, then the app)"
(
  cd build/ipa/Payload/Runner.app
  for fw in Frameworks/*.framework; do
    [ -f "$fw/$(basename "$fw" .framework)" ] || continue
    codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1
  done
  codesign --force --sign - --timestamp=none Runner >/dev/null 2>&1
  codesign --force --sign - --timestamp=none . >/dev/null 2>&1
)

echo "==> Verifying every Mach-O survives an ldid signing pass"
if command -v ldid >/dev/null; then
  fails=0
  while read -r f; do
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    ldid -S "$f" >/dev/null 2>&1 || { echo "    LDID FAIL: $f"; fails=1; }
    file -b "$f" | grep -q "^Mach-O universal" && { echo "    STILL FAT: $f"; fails=1; }
  done < <(find build/ipa/Payload/Runner.app -type f)
  [ "$fails" -eq 0 ] && echo "    all Mach-O OK, none fat" || { echo "ABORT: bundle would fail to sign"; exit 1; }
else
  echo "    (ldid not installed — 'brew install ldid' to enable this check)"
fi

echo "==> Packaging"
(cd build/ipa && zip -qry "../$(basename "$OUT")" Payload)
ls -lh "$OUT"
