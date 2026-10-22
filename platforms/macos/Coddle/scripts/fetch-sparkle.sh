#!/usr/bin/env bash
# Fetch a fixed upstream distribution; stdout is its absolute directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="${CODDLE_DEPENDENCY_CACHE:-$ROOT/.build/dependencies}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd)"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
DEST="$CACHE/sparkle-$VERSION"
valid_archive() { [ -f "$ARCHIVE" ] && [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$SHA256" ]; }
if ! valid_archive; then
  TEMP="$(mktemp "$CACHE/.sparkle-download.XXXXXX")"
  trap 'rm -f "$TEMP"' EXIT
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$TEMP"
  [ "$(shasum -a 256 "$TEMP" | awk '{print $1}')" = "$SHA256" ] || { echo 'Sparkle checksum mismatch' >&2; exit 1; }
  mv "$TEMP" "$ARCHIVE"
fi
# Always unpack the verified archive. A stale or modified framework cache must
# not be trusted merely because the downloaded archive is still authentic.
TEMP="$(mktemp -d "$CACHE/.sparkle-extract.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
tar -xJf "$ARCHIVE" -C "$TEMP"
test -x "$TEMP/bin/generate_appcast"
test -d "$TEMP/Sparkle.framework"
rm -rf "$DEST"
mv "$TEMP" "$DEST"
printf '%s\n' "$DEST"
