#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle="$(zsh "$root/scripts/fetch-sparkle.sh")"
app="${1:-$root/dist/ocrsnip.app}"
if [[ $# -lt 2 ]]; then
  work="$(mktemp -d "$root/.build/update-test.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  ditto "$app" "$work/ocrsnip.app"
  app="$work/ocrsnip.app"
  swift -module-cache-path "$root/.build/module-cache" \
    "$root/regression-tests/MakeUpdateFixture.swift" "$work/test-key" "$app"
  codesign --force --sign - "$app"
  OCRSNIP_TEST_UPDATE=1 SPARKLE_PRIVATE_KEY="$(cat "$work/test-key")" \
    zsh "$root/scripts/package-update.sh" "$app" "$work/updates"
  updates="$work/updates"
else
  updates="$2"
fi
swiftc -module-cache-path "$root/.build/module-cache" -parse-as-library \
  "$root/regression-tests/UpdateProbe.swift" \
  -F "$sparkle" -framework Sparkle -framework AppKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$root/.build/UpdateProbe"
python3 "$root/regression-tests/check_updates.py" \
  "$app" "$updates" "$root/.build/UpdateProbe"
