#!/usr/bin/env bash
# Build a universal, ad-hoc signed delivery without installing it.
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-../../../dist}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
WORK="$(mktemp -d "$DEST/.build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for architecture in arm64 x86_64; do
  CODDLE_ARCH="$architecture" CODDLE_OUTPUT_DIR="$WORK/$architecture" ./build.sh
done
APP="$DEST/Coddle.app"
rm -rf "$APP"
/usr/bin/ditto "$WORK/arm64/Coddle.app" "$APP"
for component in Contents/MacOS/Coddle Contents/Resources/coddle-helper; do
  lipo -create "$WORK/arm64/Coddle.app/$component" "$WORK/x86_64/Coddle.app/$component" -output "$APP/$component"
done
scripts/sign-app.sh "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$DEST/Coddle-universal.zip"
(
  cd "$DEST"
  shasum -a 256 Coddle-universal.zip > Coddle-universal.zip.sha256
)
printf 'Built %s (signing identity: %s; not notarized)\n' "$DEST/Coddle-universal.zip" "${CODDLE_SIGN_IDENTITY:--}"
