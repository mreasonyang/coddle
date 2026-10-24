#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUTPUT="${1:-/tmp/coddle-onboarding-ui}"
if [[ $# -gt 0 ]]; then shift; fi
BUILD_ONLY=false
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--build-only" ]]; then BUILD_ONLY=true; else ARGS+=("$arg"); fi
done
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
APP="$OUTPUT/CoddleOnboardingReview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT/evidence"
clang -fobjc-arc -O2 -c PowerUI.m -o "$OUTPUT/PowerUI.o"
swiftc -D CODDLE_TESTING -parse-as-library -import-objc-header PowerUI.h \
  Sources/*.swift tests/integration/Fixture.swift tests/ui/AccessibilityTree.swift tests/onboarding/PreviewMain.swift \
  "$OUTPUT/PowerUI.o" -o "$APP/Contents/MacOS/CoddleReviewUI" \
  -framework Foundation -framework AppKit -framework ApplicationServices -framework SwiftUI -framework IOKit
cp tests/ui/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.coddle.onboarding-review.app' "$APP/Contents/Info.plist"
for resource in Resources/*.lproj; do cp -R "$resource" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP"
rm -f "$OUTPUT/evidence/report.json" "$OUTPUT/evidence/failure.txt"
if [[ "$BUILD_ONLY" == true ]]; then
  echo "$APP"
  exit 0
fi
if [[ -n "${ARGS[*]-}" ]]; then
  "$APP/Contents/MacOS/CoddleReviewUI" "${ARGS[@]}" "$OUTPUT/evidence"
else
  "$APP/Contents/MacOS/CoddleReviewUI" "$OUTPUT/evidence"
fi
if [[ " ${ARGS[*]-} " == *" --review "* ]]; then exit 0; fi
test -f "$OUTPUT/evidence/report.json"
