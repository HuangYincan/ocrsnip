#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/ocrsnip.app}"
fingerprint="$(openssl x509 -inform DER -in "$root/signing/ocrsnip.cer" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
requirement="certificate leaf = H\"$fingerprint\""
codesign --verify --deep --strict -R "=identifier \"com.acc.ocrsnip\" and $requirement" "$app"
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in \
  "$framework" \
  "$framework/Versions/B/Autoupdate" \
  "$framework/Versions/B/Updater.app" \
  "$framework/Versions/B/XPCServices/Downloader.xpc" \
  "$framework/Versions/B/XPCServices/Installer.xpc"; do
  codesign --verify --strict -R "=$requirement" "$component"
done
print -r -- "PASS: app and update helpers share the fixed signing certificate ($fingerprint)"
