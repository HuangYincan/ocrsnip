#!/bin/zsh
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == 'true' ]] || { print -u2 'This script is only for the isolated GitHub Actions runner.'; exit 1; }
: "${MACOS_SIGNING_P12:?Missing MACOS_SIGNING_P12 secret}"
: "${MACOS_SIGNING_PASSWORD:?Missing MACOS_SIGNING_PASSWORD secret}"
: "${RUNNER_TEMP:?Missing RUNNER_TEMP}"
: "${GITHUB_ENV:?Missing GITHUB_ENV}"
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$RUNNER_TEMP/ocrsnip-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
python3 - "$work/certificate.p12" <<'PY'
import base64, os, pathlib, sys
encoded = ''.join(os.environ['MACOS_SIGNING_P12'].split())
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(encoded, validate=True))
PY
keychain="$RUNNER_TEMP/ocrsnip-signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$MACOS_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
# Unattended access belongs only in the temporary CI keychain, never the login keychain.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
OCRSNIP_SIGN_KEYCHAIN="$keychain" zsh "$root/scripts/signing-identity.sh" >/dev/null
print -r -- "OCRSNIP_SIGN_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
