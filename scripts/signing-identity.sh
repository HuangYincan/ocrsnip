#!/bin/zsh
set -euo pipefail

# Print a stable codesigning identity. Ad-hoc (`-`) signatures embed a
# CDHash in the designated requirement, so TCC treats every rebuild as a
# new app and re-prompts for Accessibility / Screen Recording.
# A certificate-backed identity keeps the requirement as:
#   identifier "com.acc.ocrsnip" and certificate root/leaf = H"<cert>"
#
# Do not treat this identity as a trust anchor. Importing with
# `-T /usr/bin/codesign` would let any local process sign as
# com.acc.ocrsnip and reuse Screen Recording / Accessibility grants.
# Headless CI can set OCRSNIP_SIGN_TRUST_CODESIGN=1.

if [[ -n "${OCRSNIP_SIGN_IDENTITY:-}" ]]; then
  print -r -- "$OCRSNIP_SIGN_IDENTITY"
  exit 0
fi

identity="ocrsnip Developer"

if [[ "${OCRSNIP_RESET_DEV_CERT:-}" == "1" ]]; then
  security delete-identity -c "$identity" >/dev/null 2>&1 || true
fi

if security find-certificate -c "$identity" >/dev/null 2>&1; then
  print -r -- "$identity"
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

openssl req -new -x509 -days 3650 -nodes -sha256 \
  -subj "/CN=${identity}/O=ocrsnip" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$workdir/key.pem" \
  -out "$workdir/cert.pem" >/dev/null 2>&1

# macOS `security import` rejects OpenSSL 3's default PKCS#12 MAC.
openssl pkcs12 -export -legacy \
  -inkey "$workdir/key.pem" \
  -in "$workdir/cert.pem" \
  -out "$workdir/ocrsnip.p12" \
  -passout pass:ocrsnip \
  -name "$identity" >/dev/null 2>&1

import_args=(
  "$workdir/ocrsnip.p12"
  -k "$HOME/Library/Keychains/login.keychain-db"
  -P ocrsnip
)
if [[ -n "${CI:-}" || "${OCRSNIP_SIGN_TRUST_CODESIGN:-}" == "1" ]]; then
  # CI has no keychain prompt. Local builds should leave this unset.
  import_args+=(-T /usr/bin/codesign -T /usr/bin/security)
else
  print -r -- "warning: codesign will ask for keychain access; do not treat '$identity' as a trust anchor" >&2
fi

security import "${import_args[@]}" >/dev/null

print -r -- "$identity"
