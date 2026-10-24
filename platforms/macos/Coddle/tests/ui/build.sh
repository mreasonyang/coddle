#!/usr/bin/env bash
# Build and run the isolated production UI. No user config or hardware services
# are used. Give a different output directory to preserve an interactive build.
# Usage: tests/ui/build.sh [OUTPUT_DIR] [build|render|e2e|interactive] [fixture args...]
# Example: tests/ui/build.sh /tmp/coddle-ui render --languages en,ja,es --themes liquidGlass
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTPUT_DIR="${1:-build/ui-review}"
MODE="${2:-render}"
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -gt 0 ]; then shift; fi
case "$MODE" in build|render|e2e|interactive) ;; *) echo "Unknown mode: $MODE" >&2; exit 2 ;; esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP="$OUTPUT_DIR/CoddleReviewUI.app"
CACHE="${CODDLE_UI_MODULE_CACHE:-$OUTPUT_DIR/module-cache}"
TARGET_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
TARGET="${CODDLE_UI_ARCH:-$(uname -m)}-apple-macos$TARGET_OS"
mkdir -p "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -target "$TARGET" -fobjc-arc -O2 -c PowerUI.m -o "$OUTPUT_DIR/PowerUI.o"
swiftc -O -D CODDLE_TESTING -parse-as-library -target "$TARGET" \
  -module-cache-path "$CACHE" -import-objc-header PowerUI.h \
  Sources/*.swift tests/integration/Fixture.swift tests/ui/AccessibilityTree.swift tests/ui/PreviewMain.swift \
  "$OUTPUT_DIR/PowerUI.o" -o "$OUTPUT_DIR/CoddleReviewUI" \
  -framework Foundation -framework AppKit -framework ApplicationServices -framework SwiftUI -framework IOKit
cp "$OUTPUT_DIR/CoddleReviewUI" "$APP/Contents/MacOS/CoddleReviewUI"
cp tests/ui/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $TARGET_OS" "$APP/Contents/Info.plist"
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Isolated UI: %s\n' "$APP"

case "$MODE" in
  render)
    rm -f "$OUTPUT_DIR/coddle-ui-evidence/render-report.json" \
      "$OUTPUT_DIR/coddle-ui-evidence/render-failure.txt"
    "$APP/Contents/MacOS/CoddleReviewUI" --render --output "$OUTPUT_DIR" "$@"
    # Rendering reports failures to disk before the app exits normally.
    test -f "$OUTPUT_DIR/coddle-ui-evidence/render-report.json"
    ;;
  e2e)
    rm -f "$OUTPUT_DIR/coddle-ui-evidence/e2e-report.json" \
      "$OUTPUT_DIR/coddle-ui-evidence/e2e-failure.txt"
    "$APP/Contents/MacOS/CoddleReviewUI" --e2e --output "$OUTPUT_DIR" "$@"
    test -f "$OUTPUT_DIR/coddle-ui-evidence/e2e-report.json"
    ;;
  interactive)
    open -n "$APP" --args --output "$OUTPUT_DIR/interactive" "$@"
    ;;
esac
