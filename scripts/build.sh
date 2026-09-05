#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
identity="$("$root/scripts/signing-identity.sh")"
app="${OCRSNIP_APP_DIR:-$root/dist/ocrsnip.app}"

mkdir -p "$app/Contents/MacOS"

swiftc \
  "$root/ScreenCaptureStrategy.swift" \
  "$root/OCRClipboard.swift" \
  "$root/LaunchAtLogin.swift" \
  "$root/main.swift" \
  -o "$app/Contents/MacOS/ocrsnip" \
  -framework AppKit \
  -framework Vision \
  -framework Carbon \
  -framework ScreenCaptureKit \
  -framework ApplicationServices \
  -framework ServiceManagement

cp "$root/Info.plist" "$app/Contents/Info.plist"

codesign --force \
  --sign "$identity" \
  --identifier com.acc.ocrsnip \
  "$app/Contents/MacOS/ocrsnip"
codesign --force \
  --sign "$identity" \
  --identifier com.acc.ocrsnip \
  "$app"

print -r -- "signed $app as $identity"
codesign -d -r- "$app" 2>&1 | sed -n 's/^.*designated => /designated => /p'
