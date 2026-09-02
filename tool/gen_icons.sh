#!/usr/bin/env bash
# Regenerate assets/icon/* from the two source files in assets/New_Icon#2/,
# then run flutter_launcher_icons.
#
# Apple platforms do NOT come from here: they ship Vault_icon.icon (Icon
# Composer) wired straight into the Xcode projects, which is what gives the
# real light/dark/tinted/clear appearances on iOS 26 / macOS 26. What this
# script produces for iOS/macOS is only the pre-.icon fallback.
#
# Requires: rsvg-convert and magick (brew install librsvg imagemagick).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC_DIR="assets/New_Icon#2"
ICON_BUNDLE="$SRC_DIR/Vault_icon.icon"
OUT="assets/icon"
mkdir -p "$OUT"

# The .icon's layers are the artwork WITHOUT the background plate (Icon
# Composer draws that itself from "fill": "automatic"). Stack them into one
# SVG — that flat flower is what Android's adaptive icon needs, since the
# launcher supplies its own background and mask.
python3 - "$ICON_BUNDLE/Assets" > /tmp/vault_flower.svg <<'PY'
import sys, re, pathlib
d = pathlib.Path(sys.argv[1])
# icon.json lists groups bottom-first; layer 1 is the topmost (glass) layer.
bodies = []
for name in ["4 – Layer.svg", "3 – Layer.svg", "2 – Layer.svg", "1 – Layer.svg"]:
    t = (d / name).read_text().strip()
    t = re.sub(r'^<svg[^>]*>', '', t)
    bodies.append(re.sub(r'</svg>\s*$', '', t).strip())
print('<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" '
      'xmlns="http://www.w3.org/2000/svg">')
print("\n".join(bodies))
print('</svg>')
PY
rsvg-convert -w 1024 -h 1024 -b none /tmp/vault_flower.svg -o /tmp/vault_flower.png

# Apple fallback: the artist's PNG as-is (squircle baked in, alpha corners).
cp "$SRC_DIR/Vault_Icon.png" "$OUT/icon_apple.png"

# Windows/web/Android-legacy: flower on an opaque white square. These launchers
# render the file as given, so the squircle's transparent corners would show.
magick /tmp/vault_flower.png -resize 870x870 -background white \
  -gravity center -extent 1024x1024 -alpha remove -alpha off "$OUT/icon_square.png"

# Android adaptive foreground: FULL BLEED on purpose. flutter_launcher_icons
# emits `<inset android:inset="16%">` in ic_launcher.xml, which is what puts
# the art inside the 66% safe zone every launcher mask keeps. Pre-shrinking
# here too would inset it twice and leave a tiny flower adrift in white.
cp /tmp/vault_flower.png "$OUT/icon_fg.png"

# Android 13+ themed icon: the same silhouette, flat black. Only its ALPHA is
# used — the system recolours it to match the wallpaper.
magick "$OUT/icon_fg.png" -alpha extract /tmp/vault_mask.png
magick -size 1024x1024 xc:"#000000" /tmp/vault_mask.png -alpha off \
  -compose CopyOpacity -composite "$OUT/icon_mono.png"

# iOS <26 fallback appearances: transparent so iOS fills the dark background
# itself, and a grayscale copy for tinted mode.
magick /tmp/vault_flower.png -resize 870x870 -background none \
  -gravity center -extent 1024x1024 "$OUT/icon_dark_transparent.png"
magick "$OUT/icon_square.png" -colorspace Gray -alpha off "$OUT/icon_tinted.png"

echo "assets/icon regenerated:"
ls -1 "$OUT"

dart run flutter_launcher_icons

# MUST come after flutter_launcher_icons: that tool resets the iOS project's
# ASSETCATALOG_COMPILER_APPICON_NAME to "AppIcon", which silently drops the
# Icon Composer icon (and with it every dark/tinted appearance) from release
# builds. Re-point it and keep the .icon bundles in the Xcode projects fresh.
cp -R "$ICON_BUNDLE" ios/Runner/
cp -R "$ICON_BUNDLE" macos/Runner/
find ios/Runner/Vault_icon.icon macos/Runner/Vault_icon.icon -name '.DS_Store' -delete
ruby tool/wire_icon_composer.rb
