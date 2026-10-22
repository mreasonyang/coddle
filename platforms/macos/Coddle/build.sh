#!/usr/bin/env bash
# Build the app and all regression runners with the declared minimum OS.
set -euo pipefail
cd "$(dirname "$0")"

OUTPUT_ROOT="${CODDLE_OUTPUT_DIR:-.}"
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
APP="$OUTPUT_ROOT/Coddle.app"
BUILD="$OUTPUT_ROOT/build"
TARGET_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
TARGET_ARCH="${CODDLE_ARCH:-$(uname -m)}"
TARGET="$TARGET_ARCH-apple-macos$TARGET_OS"
# Keep caches writable in restricted development environments.
CACHE="${CODDLE_MODULE_CACHE:-$OUTPUT_ROOT/module-cache}"
mkdir -p "$CACHE"
SWIFT_FLAGS=(-O -target "$TARGET" -module-cache-path "$CACHE")
FRAMEWORKS=(-framework Foundation -framework AppKit -framework SwiftUI -framework IOKit)
SPARKLE="$(scripts/fetch-sparkle.sh)"
UPDATER_FLAGS=(-F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD"

printf 'Building %s\n' "$TARGET"
clang -target "$TARGET" -c -fobjc-arc -O2 -o "$BUILD/PowerUI.o" PowerUI.m
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -import-objc-header PowerUI.h \
  Sources/*.swift "$BUILD/PowerUI.o" -o "$BUILD/Coddle" "${FRAMEWORKS[@]}" "${UPDATER_FLAGS[@]}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Coddle" "$APP/Contents/MacOS/Coddle"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Assets/AppIcon.icns Assets/MenuBarIconTemplate.png Assets/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
swiftc "${SWIFT_FLAGS[@]}" helper/main.swift Sources/HelperCommand.swift Sources/BoundedIO.swift \
  -o "$BUILD/coddle-helper" -framework Foundation
cp "$BUILD/coddle-helper" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/coddle-helper"
# Resources are sealed as data by the app signature; --deep does not sign this
# standalone executable. Sign it explicitly so every architecture is covered.
scripts/sign-app.sh "$APP"

swiftc "${SWIFT_FLAGS[@]}" -import-objc-header PowerUI.h \
  Sources/BatteryReader.swift Sources/PowerUIBridge.swift Sources/Config.swift Sources/OnboardingState.swift selftest/main.swift \
  "$BUILD/PowerUI.o" -o "$BUILD/coddle-selftest" -framework Foundation -framework IOKit
swiftc "${SWIFT_FLAGS[@]}" \
  Sources/SmartPolicy.swift Sources/Config.swift Sources/OnboardingState.swift Sources/BatteryReader.swift \
  Sources/ChargeOverride.swift Sources/ChargeOverrideMonitor.swift \
  Sources/Localization.swift Sources/HelperManager.swift Sources/BoundedIO.swift Sources/BagGuard.swift \
  Sources/AwayDetector.swift Sources/HelperCommand.swift Sources/Theme.swift Sources/SliderInput.swift \
  "$(pwd)/tests/main.swift" -o "$BUILD/coddle-tests" "${FRAMEWORKS[@]}" -framework Combine
swiftc "${SWIFT_FLAGS[@]}" Sources/SmartPolicy.swift Sources/AwayDetector.swift \
  Sources/NetworkFingerprintParser.swift tests/policy/main.swift -o "$BUILD/coddle-policy-tests"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library Sources/KeepAwake.swift \
  tests/assertions/RegressionMain.swift -o "$BUILD/coddle-assertion-tests" -framework Foundation -framework IOKit
# Compile the real AppModel and UI; only the entry point and external services
# differ. No implementation is copied or rewritten for these tests.
swiftc "${SWIFT_FLAGS[@]}" -D CODDLE_TESTING -parse-as-library -import-objc-header PowerUI.h \
  Sources/*.swift tests/integration/*.swift "$BUILD/PowerUI.o" \
  -o "$BUILD/coddle-integration-tests" "${FRAMEWORKS[@]}"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -import-objc-header PowerUI.h \
  Sources/KeepAwake.swift Sources/PowerUIBridge.swift \
  tests/hardware/SmokeMain.swift "$BUILD/PowerUI.o" -o "$BUILD/coddle-hardware-smoke" \
  -framework Foundation -framework IOKit -framework CoreGraphics
printf 'Built %s\nTest: ./test.sh "%s"\n' "$APP" "$BUILD"
