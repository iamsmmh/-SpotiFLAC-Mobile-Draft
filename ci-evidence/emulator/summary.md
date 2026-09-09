# Emulator smoke — evidence
- run: https://github.com/iamsmmh/-SpotiFLAC-Mobile-Draft/actions/runs/34413232165
- sha: e15d618e872f20df5bae247147bb0752d9f24e4e
- device: API 34 google_apis x86_64 (swiftshader), release APK

## Phase log
phase=wait-for-device
phase=install-apk
phase=launch-app
phase=navigate-tabs
result=FAIL: app process died during tab navigation

## Focus
  mCurrentFocus=Window{90b8dff u0 com.android.settings/com.android.settings.FallbackHome}
  mFocusedApp=ActivityRecord{c6a5c90 u0 com.android.settings/.FallbackHome t5}

## Monkey
(not run)

## Fatal
(none)

## gomobile build
(ok, no output)
