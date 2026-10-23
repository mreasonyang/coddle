#!/usr/bin/env bash
# Compile the actual menu implementation and drive native AppKit menu tracking.
# No Coddle model, power service, helper, or persisted settings are started.
# Requires a logged-in macOS GUI session; a tiny test window appears briefly.
# Usage: tests/menu-lifecycle/run.sh [OUTPUT_DIR]
# CODDLE_MENU_THEME_SOURCE can point to a historical Theme.swift for regression
# checks (the coordinator must be internal in that temporary source copy).
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTPUT_DIR="${1:-build/menu-lifecycle}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP="$OUTPUT_DIR/CoddleMenuLifecycle.app"
TARGET_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
TARGET="$(uname -m)-apple-macos$TARGET_OS"
THEME_SOURCE="${CODDLE_MENU_THEME_SOURCE:-Sources/Theme.swift}"
mkdir -p "$OUTPUT_DIR/module-cache" "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target "$TARGET" \
  -module-cache-path "$OUTPUT_DIR/module-cache" \
  "$THEME_SOURCE" Sources/SliderInput.swift Sources/Config.swift \
  Sources/OnboardingState.swift tests/menu-lifecycle/Main.swift \
  -o "$APP/Contents/MacOS/CoddleMenuLifecycle" \
  -framework AppKit -framework SwiftUI -framework Foundation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CoddleMenuLifecycle</string>
  <key>CFBundleIdentifier</key><string>com.coddle.tests.menu-lifecycle</string>
  <key>CFBundleName</key><string>Coddle Menu Lifecycle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# AppKit may emit unrelated system diagnostics; report only the harness's
# intentionally content-free stdout assertions and its process exit status.
"$APP/Contents/MacOS/CoddleMenuLifecycle" 2>/dev/null
