#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
expected="$(openssl x509 -inform DER -in "$root/signing/ocrsnip.cer" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
identity="${OCRSNIP_SIGN_IDENTITY:-$expected}"

# Ad-hoc signing must be explicitly opted into for isolated tests.
if [[ "$identity" == '-' && "${OCRSNIP_ALLOW_ADHOC:-}" == '1' ]]; then
  print -r -- '-'
  exit 0
fi
[[ "$identity" == "$expected" ]] || {
  print -u2 'Signing identity must match signing/ocrsnip.cer. Refusing to change the app identity.'
  exit 1
}
keychain_args=()
[[ -z "${OCRSNIP_SIGN_KEYCHAIN:-}" ]] || keychain_args+=("$OCRSNIP_SIGN_KEYCHAIN")
# Include self-signed identities (without -v); no trust-root changes are needed.
identities="$(security find-identity -p codesigning "${keychain_args[@]}")"
[[ "$identities" == *"$expected"* ]] || {
  print -u2 'The fixed ocrsnip signing identity is missing. Import its original .p12 backup; do not generate a replacement certificate.'
  exit 1
}
print -r -- "$expected"
