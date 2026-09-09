#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Android emulator device test for SpotiFLAC Mobile.
#
# Runs INSIDE the reactivecircus/android-emulator-runner action. The action
# executes its `script:` input LINE BY LINE via `sh -c`, so any multi-line
# construct (for loops, if blocks) breaks with exit code 2. Keep this file as
# the single source of truth and point the workflow at it with a one-liner:
#
#     script: bash "$GITHUB_WORKSPACE/.github/scripts/emulator-device-test.sh"
#
# Phases (recorded in smoke-status.txt):
#   wait-for-device -> install-apk -> launch-app -> navigate-tabs ->
#   rotation -> monkey-stress -> final-analysis
#
# The test FAILS on: failed install, dead process at any point, FATAL
# EXCEPTION or ANR in logcat, or no Flutter log output. Screenshots are
# captured at every phase for the committed evidence.
#
# Env: APP_ID (e.g. com.zarz.spotiflac — the *release* applicationId; debug
# builds append ".debug", and this script installs the release APK).
# ---------------------------------------------------------------------------
set -uo pipefail

STATUS=smoke-status.txt
: > "$STATUS"
phase() { echo "phase=$1" >> "$STATUS"; echo "=== $1"; }

fail() {
  echo "::error::$*"
  echo "result=FAIL: $*" >> "$STATUS"
  adb logcat -d -b crash > crash-log.txt 2>/dev/null || true
  adb logcat -d > logcat.txt 2>/dev/null || true
  exit 1
}

phase "wait-for-device"
adb wait-for-device || fail "adb wait-for-device failed"
timeout 300 bash -c 'until adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do sleep 3; done' \
  || fail "emulator did not finish booting in 300s"

phase "install-apk"
adb install -r build/app/outputs/flutter-apk/app-release.apk \
  || fail "APK install failed"
adb logcat -c
adb shell svc power stayon true || true
adb shell pm grant "$APP_ID" android.permission.POST_NOTIFICATIONS || true
adb shell pm grant "$APP_ID" android.permission.READ_MEDIA_AUDIO || true
adb shell pm grant "$APP_ID" android.permission.WRITE_EXTERNAL_STORAGE || true

phase "launch-app"
adb shell am start -n "$APP_ID/.MainActivity" || fail "am start failed"
sleep 30
PID=$(adb shell pidof "$APP_ID" | tr -d '\r')
[ -n "$PID" ] || fail "app process not alive 30s after launch (stuck/crashed at splash?)"
echo "app alive (pid $PID)"
adb shell dumpsys window 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" | head -2 > focus.txt || true
grep -q "$APP_ID" focus.txt \
  || echo "::warning::app may not be in foreground: $(cat focus.txt 2>/dev/null)"
adb shell screencap -p /sdcard/shot1_boot.png
adb pull /sdcard/shot1_boot.png shot1_boot.png || true
adb shell uiautomator dump /sdcard/ui1.xml >/dev/null 2>&1 || true
adb pull /sdcard/ui1.xml ui1.xml >/dev/null 2>&1 || true

# ---- Exercise the bottom NavigationBar (Home / Library / Store / Settings)
phase "navigate-tabs"
SIZE=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | head -1)
W=${SIZE%x*}; H=${SIZE#*x}
echo "screen ${W}x${H}"
NY=$((H - 84))          # NavigationBar band
i=0
for frac in 0.125 0.375 0.625 0.875; do
  i=$((i+1))
  X=$(awk -v w="$W" -v f="$frac" 'BEGIN{printf "%d", w*f}')
  adb shell input tap "$X" "$NY"
  sleep 5
  adb shell screencap -p "/sdcard/shot2_tab${i}.png"
  adb pull "/sdcard/shot2_tab${i}.png" "shot2_tab${i}.png" || true
done
adb shell uiautomator dump /sdcard/ui2.xml >/dev/null 2>&1 || true
adb pull /sdcard/ui2.xml ui2.xml >/dev/null 2>&1 || true
PID=$(adb shell pidof "$APP_ID" | tr -d '\r')
[ -n "$PID" ] || fail "app process died during tab navigation"

# ---- Rotation stress (portrait -> landscape -> portrait)
phase "rotation"
adb shell settings put system accelerometer_rotation 0 || true
adb shell settings put system user_rotation 1 || true
sleep 5
adb shell screencap -p /sdcard/shot3_landscape.png
adb pull /sdcard/shot3_landscape.png shot3_landscape.png || true
adb shell settings put system user_rotation 0 || true
sleep 4
PID=$(adb shell pidof "$APP_ID" | tr -d '\r')
[ -n "$PID" ] || fail "app process died during rotation"

# ---- Monkey stress (app package only; crashes surface as FATAL EXCEPTION)
phase "monkey-stress"
adb shell monkey -p "$APP_ID" --throttle 120 \
  --pct-touch 60 --pct-motion 25 --pct-nav 5 --pct-majornav 5 \
  --pct-appswitch 0 --pct-trackball 0 --pct-anything 5 \
  -s 20260910 400 > monkey.txt 2>&1 || true
tail -n 5 monkey.txt || true
sleep 6
adb shell screencap -p /sdcard/shot4_after_monkey.png
adb pull /sdcard/shot4_after_monkey.png shot4_after_monkey.png || true
PID=$(adb shell pidof "$APP_ID" | tr -d '\r')
[ -n "$PID" ] || fail "app process died during monkey stress"

# ---- Final analysis
phase "final-analysis"
adb logcat -d > logcat.txt
if grep -q "FATAL EXCEPTION" logcat.txt; then
  grep -A 40 "FATAL EXCEPTION" logcat.txt | head -80 > fatal.txt || true
  fail "FATAL EXCEPTION detected (see fatal.txt)"
fi
if grep -qE "ANR in .*${APP_ID}|Input dispatching timed out .*${APP_ID}" logcat.txt; then
  fail "ANR detected for ${APP_ID}"
fi
grep -qiE "flutter|SpotiFLAC" logcat.txt \
  || fail "no app log output captured"
adb shell screencap -p /sdcard/smoke.png
adb pull /sdcard/smoke.png smoke.png || true
echo "result=PASS" >> "$STATUS"
echo "SMOKE PASSED"
