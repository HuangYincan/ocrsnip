#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
destination="$root/.build/sparkle-$version"

if [[ -f "$destination/.verified-$sha256" && -d "$destination/Sparkle.framework" && -x "$destination/bin/generate_appcast" ]]; then
  print -r -- "$destination"
  exit 0
fi

mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/sparkle-download.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
  -o "$work/Sparkle.tar.xz"
actual="$(shasum -a 256 "$work/Sparkle.tar.xz" | cut -d ' ' -f 1)"
[[ "$actual" == "$sha256" ]] || { print -u2 'Sparkle download checksum mismatch'; exit 1; }
mkdir -p "$destination"
tar -xf "$work/Sparkle.tar.xz" -C "$destination"
touch "$destination/.verified-$sha256"
print -r -- "$destination"
