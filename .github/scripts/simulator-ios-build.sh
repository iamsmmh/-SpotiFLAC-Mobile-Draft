#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the Runner app for the iOS *simulator* with the Xcode 26 workarounds
# the device archive path already uses (see archive-ios.sh):
#
#   * Xcode 26 does not consistently propagate CocoaPods' conditional
#     framework search path to Objective-C plugin targets, so the matching
#     Flutter.xcframework simulator slice is resolved once and passed as an
#     inherited workspace-wide search path.
#   * SWIFT_ENABLE_EXPLICIT_MODULES=NO (explicit modules break some plugin
#     builds on this toolchain).
#
# Usage: simulator-ios-build.sh <derived-data-path> <log-path>
#
# On success the app bundle is at
#   <derived-data-path>/Build/Products/Debug-iphonesimulator/Runner.app
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DERIVED_DATA="${1:?derived data path required}"
LOG="${2:-${RUNNER_TEMP:-/tmp}/xcodebuild-simulator.log}"

cd "$REPO_ROOT/ios"

# Flutter's CocoaPods engine pod is intentionally only a placeholder; the real
# module lives in the SDK cache. Resolve the simulator slice once (Debug
# configuration -> ios-debug artifacts).
FLUTTER_ROOT_PATH="$(sed -n 's/^FLUTTER_ROOT=//p' Flutter/Generated.xcconfig | head -1)"
FLUTTER_XCFRAMEWORK="$FLUTTER_ROOT_PATH/bin/cache/artifacts/engine/ios-debug/Flutter.xcframework"
FLUTTER_SIM_SLICE=""
for candidate in "$FLUTTER_XCFRAMEWORK"/ios-*simulator*; do
  if [ -d "$candidate" ]; then
    FLUTTER_SIM_SLICE="$candidate"
    break
  fi
done
if [ -z "$FLUTTER_ROOT_PATH" ] || [ -z "$FLUTTER_SIM_SLICE" ] \
   || [ ! -f "$FLUTTER_SIM_SLICE/Flutter.framework/Modules/module.modulemap" ]; then
  echo "::error::Flutter simulator framework/module map is missing under $FLUTTER_XCFRAMEWORK" >&2
  exit 1
fi
echo "==> Flutter simulator framework: $FLUTTER_SIM_SLICE"

echo "==> Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
echo "==> Available simulator runtimes:"
xcrun simctl list runtimes available 2>/dev/null | grep '^iOS' || echo "    (none)"

set +o pipefail
xcodebuild build \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  EXPANDED_CODE_SIGN_IDENTITY="" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  "FRAMEWORK_SEARCH_PATHS=\$(inherited) $FLUTTER_SIM_SLICE" \
  2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -o pipefail

if [ "$STATUS" -ne 0 ]; then
  echo "::group::xcodebuild errors"
  grep -nE "error:|fatal error:|Undefined symbol|ld: |clang: error|Command .* failed|SwiftCompile" "$LOG" | head -100 || true
  echo "::endgroup::"
  exit "$STATUS"
fi

APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Runner.app"
if [ ! -d "$APP" ]; then
  echo "::error::expected app bundle missing: $APP" >&2
  exit 1
fi
echo "==> Built $APP"
