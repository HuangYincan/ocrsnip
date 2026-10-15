#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ocrsnip-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cache="${TMPDIR:-/tmp}/ocrsnip-test-module-cache"
python3 "$root/regression-tests/replay_ocr_capture.py" "$work" "$cache"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$root/OCRClipboard.swift" "$root/regression-tests/OCRClipboardTests.swift" \
  -o "$work/ocr-tests" -framework AppKit -framework Vision
"$work/ocr-tests" "$@"
