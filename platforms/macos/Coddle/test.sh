#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD="${1:-build}"
BUILD="$(cd "$BUILD" && pwd)"
RUN="$(mktemp -d "${TMPDIR:-/tmp}/coddle-tests.XXXXXX")"
cleanup() {
  result=$?
  if [ "$result" -ne 0 ] && [ -f "$RUN/ui-review/coddle-ui-evidence/render-failure.txt" ]; then
    cat "$RUN/ui-review/coddle-ui-evidence/render-failure.txt" >&2
  fi
  rm -rf "$RUN"
  exit "$result"
}
trap cleanup EXIT
python3 Resources/i18n/check.py --sources
"$BUILD/coddle-tests"
"$BUILD/coddle-policy-tests"
"$BUILD/coddle-assertion-tests"
"$BUILD/coddle-integration-tests"
"$BUILD/coddle-selftest"
# Render the real panel and measure it the way the menu bar popover sizes
# itself. The fixed-size Dock window cannot catch a collapsed scroll region.
tests/ui/build.sh "$RUN/ui-review" build
UI="$RUN/ui-review/CoddleReviewUI.app/Contents/MacOS/CoddleReviewUI"
# cacheDisplay cannot composite native glass layers. Use opaque layout captures
# for the six-language matrix and native screenshots for glass visual acceptance.
rm -f "$RUN/ui-review/coddle-ui-evidence/render-report.json" \
  "$RUN/ui-review/coddle-ui-evidence/render-failure.txt" \
  "$RUN/ui-review/coddle-ui-evidence/e2e-report.json"
"$UI" --render --output "$RUN/ui-review" --languages en,zh-Hans,zh-Hant,ja,ko,es \
  --themes liquidGlass,classic --reduce-transparency true
test -f "$RUN/ui-review/coddle-ui-evidence/render-report.json"
# Fitting panels stay still; overflow keeps a fixed backdrop and reachable footer.
rm -f "$RUN/ui-review/coddle-ui-evidence/scroll-viewport-report.json"
"$UI" --render --audit scroll-viewport --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/scroll-viewport-report.json"
test ! -f "$RUN/ui-review/coddle-ui-evidence/render-failure.txt"
# Keep telemetry columns equal in every locale and state, with complete AX values.
rm -f "$RUN/ui-review/coddle-ui-evidence/power-flow-report.json"
"$UI" --render --audit power-flow --output "$RUN/ui-review" --reduce-transparency true
test -f "$RUN/ui-review/coddle-ui-evidence/power-flow-report.json"
test ! -f "$RUN/ui-review/coddle-ui-evidence/render-failure.txt"
# Interaction uses native glass; bitmap layout captures temporarily use Classic.
rm -f "$RUN/ui-review/coddle-ui-evidence/child-options-report.json"
"$UI" --render --audit child-options --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/child-options-report.json"
test ! -f "$RUN/ui-review/coddle-ui-evidence/render-failure.txt"
"$UI" --e2e --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/e2e-report.json"
# Cleanup evidence must await the same asynchronous OFF/restore operations.
rm -f "$RUN/ui-review/coddle-ui-evidence/cleanup-report.json"
"$RUN/ui-review/CoddleReviewUI.app/Contents/MacOS/CoddleReviewUI" \
  --render --audit cleanup --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/cleanup-report.json"
"$RUN/ui-review/CoddleReviewUI.app/Contents/MacOS/CoddleReviewUI" \
  --render --audit quit-cleanup --output "$RUN/ui-review"
python3 - "$RUN/ui-review/coddle-ui-evidence/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state["cleaned"]
assert not state["systemAssertionActive"] and not state["displayAssertionActive"]
assert state["helperWrites"][-1] is False
PY
# The periodic app list must not resize the mounted panel as samples change.
rm -f "$RUN/ui-review/coddle-ui-evidence/activity-refresh-report.json"
"$RUN/ui-review/CoddleReviewUI.app/Contents/MacOS/CoddleReviewUI" \
  --render --audit activity --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/activity-refresh-report.json"
# Sample the in-flight frames too: a settled-height check misses transient banners.
rm -f "$RUN/ui-review/coddle-ui-evidence/activity-motion-report.json" \
  "$RUN/ui-review/coddle-ui-evidence/render-failure.txt"
"$RUN/ui-review/CoddleReviewUI.app/Contents/MacOS/CoddleReviewUI" \
  --render --audit activity-motion --output "$RUN/ui-review"
test -f "$RUN/ui-review/coddle-ui-evidence/activity-motion-report.json"
test ! -f "$RUN/ui-review/coddle-ui-evidence/render-failure.txt"
APP="$(dirname "$BUILD")/Coddle.app"
codesign --verify --deep --strict --all-architectures "$APP"
codesign --verify --strict --all-architectures "$APP/Contents/Resources/coddle-helper"
python3 tests/helper_socket_regression.py --output-dir "$RUN/regression"
python3 tests/helper_install_regression.py --output-dir "$RUN/regression"
python3 tests/powerui_bridge_regression.py --output-dir "$RUN/regression"
bash tests/onboarding/build.sh "$RUN/onboarding-review"
