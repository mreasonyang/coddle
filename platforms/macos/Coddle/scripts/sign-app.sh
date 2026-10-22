#!/usr/bin/env bash
# Sign inside out, retaining Sparkle's XPC/Updater structure and symlinks.
set -euo pipefail
APP="$1"
IDENTITY="${CODDLE_SIGN_IDENTITY:--}"
FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != - ]; then FLAGS+=(--options runtime --timestamp); fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE" ]; then
  for service in "$SPARKLE"/XPCServices/*.xpc; do codesign "${FLAGS[@]}" "$service"; done
  codesign "${FLAGS[@]}" "$SPARKLE/Autoupdate"
  codesign "${FLAGS[@]}" "$SPARKLE/Updater.app"
  codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign "${FLAGS[@]}" "$APP/Contents/Resources/coddle-helper"
codesign "${FLAGS[@]}" "$APP"
codesign --verify --strict --all-architectures "$APP/Contents/Resources/coddle-helper"
codesign --verify --deep --strict --all-architectures "$APP"
