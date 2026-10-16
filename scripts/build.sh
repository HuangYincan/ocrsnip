#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle="$(zsh "$root/scripts/fetch-sparkle.sh")"
identity="$("$root/scripts/signing-identity.sh")"
keychain_args=()
[[ -z "${OCRSNIP_SIGN_KEYCHAIN:-}" ]] || keychain_args+=(--keychain "$OCRSNIP_SIGN_KEYCHAIN")
app="${OCRSNIP_APP_DIR:-$root/dist/ocrsnip.app}"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$root/assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"

swiftc \
  "$root/ScreenCaptureStrategy.swift" \
  "$root/OCRClipboard.swift" \
  "$root/LaunchAtLogin.swift" \
  "$root/AppUpdater.swift" \
  "$root/main.swift" \
  -o "$app/Contents/MacOS/ocrsnip" \
  -module-cache-path "$root/.build/module-cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  -F "$app/Contents/Frameworks" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit \
  -framework Vision \
  -framework Carbon \
  -framework ScreenCaptureKit \
  -framework ApplicationServices \
  -framework ServiceManagement

cp "$root/Info.plist" "$app/Contents/Info.plist"

# Sign nested helpers inside-out; never use --deep to sign the bundle.
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in \
  "$framework/Versions/B/XPCServices/Downloader.xpc" \
  "$framework/Versions/B/XPCServices/Installer.xpc" \
  "$framework/Versions/B/Autoupdate" \
  "$framework/Versions/B/Updater.app" \
  "$framework"; do
  codesign --force --sign "$identity" "${keychain_args[@]}" --preserve-metadata=entitlements "$component"
done

codesign --force \
  --sign "$identity" \
  "${keychain_args[@]}" \
  --identifier com.acc.ocrsnip \
  "$app/Contents/MacOS/ocrsnip"
codesign --force \
  --sign "$identity" \
  "${keychain_args[@]}" \
  --identifier com.acc.ocrsnip \
  "$app"

codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$identity" != '-' ]]; then
  zsh "$root/scripts/verify-signing.sh" "$app"
fi

print -r -- "signed $app as $identity"
codesign -d -r- "$app" 2>&1 | sed -n 's/^.*designated => /designated => /p'
