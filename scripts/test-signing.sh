#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="$(zsh "$root/scripts/signing-identity.sh")"
keychain_args=()
[[ -z "${OCRSNIP_SIGN_KEYCHAIN:-}" ]] || keychain_args+=(--keychain "$OCRSNIP_SIGN_KEYCHAIN")
work="$(mktemp -d "${TMPDIR:-/tmp}/ocrsnip-signing-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
print -r -- 'int main(void) { return 0; }' > "$work/a.c"
print -r -- 'int main(void) { return 1; }' > "$work/b.c"
for name in a b; do
  cc "$work/$name.c" -o "$work/$name"
  codesign --force --sign "$identity" "${keychain_args[@]}" --identifier com.acc.ocrsnip "$work/$name"
done
req_a="$(codesign -d -r- "$work/a" 2>&1 | sed -n 's/^.*designated => //p')"
req_b="$(codesign -d -r- "$work/b" 2>&1 | sed -n 's/^.*designated => //p')"
[[ -n "$req_a" && "$req_a" == "$req_b" && "$req_a" == *certificate* ]] || {
  print -u2 'FAIL: different builds must have the same certificate-based identity'; exit 1;
}
if OCRSNIP_ALLOW_ADHOC=0 OCRSNIP_SIGN_IDENTITY=- zsh "$root/scripts/signing-identity.sh" >/dev/null 2>&1; then
  print -u2 'FAIL: ad-hoc identity must not be accepted by default'; exit 1
fi
app="${1:-$root/dist/ocrsnip.app}"
zsh "$root/scripts/verify-signing.sh" "$app"
ditto "$app" "$work/untrusted.app"
codesign --force --sign - "$work/untrusted.app"
if zsh "$root/scripts/verify-signing.sh" "$work/untrusted.app" >/dev/null 2>&1; then
  print -u2 'FAIL: a re-signed app must be rejected'; exit 1
fi
print -r -- 'PASS: stable identity across builds; ad-hoc fallback and re-signed app rejected'
