#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.build" "$root/assets"
swift -module-cache-path "$root/.build/module-cache" \
  "$root/scripts/draw-icon.swift" "$root/.build/AppIcon.iconset"
iconutil -c icns "$root/.build/AppIcon.iconset" -o "$root/assets/AppIcon.icns"
cp "$root/.build/AppIcon.iconset/icon_512x512@2x.png" "$root/assets/AppIcon.png"
