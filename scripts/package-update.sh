#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle="$(zsh "$root/scripts/fetch-sparkle.sh")"
app="${1:-$root/dist/ocrsnip.app}"
output="${2:-$root/dist/updates}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
tag="${OCRSNIP_RELEASE_TAG:-v$version}"
[[ "$tag" == "v$version" ]] || { print -u2 'Release tag must match CFBundleShortVersionString'; exit 1; }
codesign --verify --deep --strict "$app"
if [[ "${OCRSNIP_TEST_UPDATE:-}" != '1' ]]; then
  zsh "$root/scripts/verify-signing.sh" "$app"
fi
work="$(mktemp -d "$root/.build/update-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/ocrsnip-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

args=(--download-url-prefix "https://github.com/HuangYincan/ocrsnip/releases/download/$tag/"
      --maximum-deltas 0 --maximum-versions 1)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # Never pass the secret on the command line or write it to a build artifact.
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$sparkle/bin/generate_appcast" --ed-key-file - "${args[@]}" "$work"
else
  "$sparkle/bin/generate_appcast" --account com.acc.ocrsnip "${args[@]}" "$work"
fi
python3 "$root/scripts/validate-appcast.py" "$app" "$work/appcast.xml" "$archive"
swift -module-cache-path "$root/.build/module-cache" \
  "$root/scripts/verify-update.swift" "$app" "$work/appcast.xml" "$archive"
mkdir -p "$output"
cp "$archive" "$work/appcast.xml" "$output/"
