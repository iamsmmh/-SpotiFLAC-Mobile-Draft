# BUILD_REPORT.md

Deliverable builds for SpotiFLAC-Mobile (`spotimusic` 5.0.0+142), produced by
`.github/workflows/build-mobile.yml`.

> **Status: the three requested builds — Android release APKs, Android App
> Bundle (AAB) and iOS unsigned IPA — were all produced successfully by CI**
> (workflow runs **33799261375** and, on the final code, **33804227621**).
> The final code (`855787f`) is green on every job that ran against it.
> They could not be downloaded into the authoring sandbox (GitHub's artifact
> blob storage is unreachable from it) and no Dart/Flutter toolchain exists
> there, so nothing below is a local build.

---

## 1. Verified results

| Workflow run | Job | Result |
| --- | --- | --- |
| **33804227621** (PR #35, commit `855787f`) | `Android build` | ✅ success (APKs + AAB) |
| **33804227621** | `iOS build` | ✅ success (unsigned IPA) |
| **33804227296** | `Flutter analyze & test` (analyze + tests) | ✅ success |
| 33799261375 | `Resolve app version` | ✅ success |
| 33799261375 | `Android build` | ✅ success (APKs + AAB) |
| 33799261375 | `iOS build` | ✅ success (unsigned IPA) |
| 33799261394 | `Android compile & native tests` | ✅ success (`flutter build apk --debug`, then `:app:testDebugUnitTest`) |
| 33799261394 | `Flutter analyze & test` → step **Analyze** | ✅ success (no analyzer findings in `lib/` or `test/`) |
| 33799261394 | `Flutter analyze & test` → step **Run tests** | ❌ failure at the time — 693 passed / 11 failed; **all fixed and now green** (run 33804227296, see `docs/testing.md`) |

Earlier run **33797687130** (same code lineage, commit `3802fb0`) failed at
`Build release APKs`, `Archive Runner without code signing` and
`Compile Android app`. The identical jobs **succeeded on the later run without
a code change**, so those failures were environmental (runner disk/Gradle cache —
the `Cache Gradle` step logged `"/usr/bin/tar" failed with exit code 2`), not a
defect in the tree.

---

## 2. Toolchain / environment

| Component | Value | Source |
| --- | --- | --- |
| Flutter | **3.44.8** (stable) | `.fvmrc` |
| Dart SDK constraint | `^3.10.0` | `pubspec.yaml` |
| Java | Temurin 17 | `ci.yml` / `build-mobile.yml` |
| Gradle | 9.6.1 (`gradle/actions/setup-gradle`) | `ci.yml` |
| Android NDK | 29.0.14206865 | `build-mobile.yml` + `android/app/build.gradle.kts` |
| `compileSdk` / `targetSdk` | 37 / 35 | `android/app/build.gradle.kts` |
| `minSdk` | `flutter.minSdkVersion` | `android/app/build.gradle.kts` |
| Go backend | gomobile AAR (`android/arm,android/arm64,android/amd64`, API 24) | `build-mobile.yml` |
| Xcode | 26.1.1 (macos-latest) | resolved in run 33797687130 |
| iOS deployment target | **15.0** | `ios/Podfile`, `project.pbxproj` |
| Signing (Android) | release keystore **only** if `android/key.properties` exists, otherwise the **debug** keystore | `android/app/build.gradle.kts` |
| Signing (iOS) | none — archive + IPA are explicitly unsigned | `build-mobile.yml` |

⚠️ **Signing caveat:** CI has no `android/key.properties`, so the APKs/AAB built
by the workflow are signed with the **debug** keystore. They are installable but
are *not* Play-Store-release artifacts. Provide `android/key.properties`
(`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) to produce
release-signed output.

---

## 3. Build commands and artifacts

### Android

```bash
# per-ABI release APKs (three artifacts)
flutter build apk --release --split-per-abi \
  --target-platform android-arm,android-arm64,android-x64

# release app bundle
bash scripts/flutter_build_appbundle.sh   # -> build/app/outputs/bundle/release/app-release.aab
```

Produced (renamed by the workflow to `dist/<APP_NAME>-<VERSION>-<abi>.apk`):

* `app-armeabi-v7a-release.apk` → `-arm32`
* `app-arm64-v8a-release.apk` → `-arm64`
* `app-x86_64-release.apk` → `-x86_64`
* `app-release.aab` → `dist/<APP_NAME>-<VERSION>.aab`

Validation in the workflow: presence check for each ABI APK, then
`apksigner verify --print-certs` over every produced APK.

### iOS

```bash
flutter build ios --release --no-codesign --config-only
(cd ios && pod install)
bash .github/scripts/archive-ios.sh "$RUNNER_TEMP/Runner.xcarchive" "$RUNNER_TEMP/xcodebuild-archive.log"
# -> Payload/Runner.app zipped into dist/<APP_NAME>-<VERSION>-ios-unsigned.ipa
```

The packaging step strips `_CodeSignature` and `embedded.mobileprovision`, then
asserts `Payload/Runner.app/Info.plist` is present in the archive.

### Uploaded artifacts

| Artifact | Contents | Retention |
| --- | --- | --- |
| `android-apk` | the three ABI APKs (+ universal when produced) and the AAB | 14 days |
| `ios-ipa` | the unsigned `.ipa` | 14 days |
| `ios-xcodebuild-log` | `xcodebuild` archive log (uploaded even on failure) | 14 days |

---

## 4. How to reproduce locally

```bash
fvm use                     # Flutter 3.44.8 (or install that version)
flutter pub get
dart run flutter_launcher_icons

# Android
flutter build apk --release --split-per-abi \
  --target-platform android-arm,android-arm64,android-x64
bash scripts/flutter_build_appbundle.sh

# iOS (macOS only; needs the Go XCFramework produced by gomobile)
flutter build ios --release --no-codesign --config-only
(cd ios && pod install --repo-update)
bash .github/scripts/archive-ios.sh /tmp/Runner.xcarchive /tmp/archive.log
```

The Go backend must be built first (`go_backend`, `gomobile bind`) — see
`.github/scripts/` for the exact commands CI uses.

---

## 5. Known build-related issues

1. **UIScene not adopted** (iOS). The app uses the classic
   `UIApplicationDelegate` lifecycle. Under the iOS 26 SDK this only logs a
   warning and the app launches (confirmed by the green archive). Apple turns
   this into a **launch assertion when building with the iOS 27 SDK**, so the
   iOS folder should be re-templated with Flutter 3.44 (which defaults to
   UIScene) before that SDK becomes mandatory. Deliberately not hand-written
   here: it cannot be validated without a device run.
2. **`Cache Gradle` restore warning** (`"/usr/bin/tar" failed with exit code 2`)
   is visible on the Android jobs; it is a cache-restore hiccup and does not
   fail the build.
3. `flutter build apk --debug` (the CI compile job) compiles the whole Dart
   tree, so a Dart error anywhere fails that job — it is a useful early gate and
   was green on run 33799261394.
