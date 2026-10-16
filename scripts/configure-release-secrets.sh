#!/bin/zsh
set -euo pipefail
# Run only after the maintainer authorizes sending these keys to this repository.
root="$(cd "$(dirname "$0")/.." && pwd)"
repository=HuangYincan/ocrsnip
umask 077
sparkle="$(zsh "$root/scripts/fetch-sparkle.sh")"
swiftc -module-cache-path "$root/.build/module-cache" \
  "$root/scripts/export-signing-identity.swift" -o "$root/.build/export-signing-identity"
work="$(mktemp -d "${TMPDIR:-/tmp}/ocrsnip-release-secrets.XXXXXX")"
trap 'rm -rf "$work"' EXIT
"$root/.build/export-signing-identity" "$root/signing/ocrsnip.cer" "$work/identity.p12" "$work/password"
"$sparkle/bin/generate_keys" --account com.acc.ocrsnip -x "$work/sparkle-key"
base64 < "$work/identity.p12" | gh secret set MACOS_SIGNING_P12 --repo "$repository"
gh secret set MACOS_SIGNING_PASSWORD --repo "$repository" < "$work/password"
gh secret set SPARKLE_PRIVATE_KEY --repo "$repository" < "$work/sparkle-key"
gh secret list --repo "$repository"
