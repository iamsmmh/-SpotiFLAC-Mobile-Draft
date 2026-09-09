# Android compile & native tests — evidence
- run: https://github.com/iamsmmh/-SpotiFLAC-Mobile-Draft/actions/runs/34413232146
- sha: e15d618e872f20df5bae247147bb0752d9f24e4e

## Steps
- success: Set up job
- success: Checkout repository
- success: Setup Java
- success: Setup Go
- success: Setup Flutter
- success: Setup Gradle
- success: Install Android SDK & NDK
- success: Build Go backend (gomobile AAR)
- success: Get Flutter dependencies
- success: Compile Android app
- success: Run native unit tests
- : Record evidence (dispatch only)
- : Post Setup Gradle
- : Post Setup Flutter
- : Post Setup Go
- : Post Setup Java
- : Post Checkout repository

## flutter build apk --debug
applies the Kotlin Gradle Plugin, which will cause build failures in future versions of Flutter. 
Please migrate your app to Built-in Kotlin using this guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers

WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): ffmpeg_kit_flutter_new_full
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.

Please check the changelogs of these plugins and upgrade to a version that supports Built-in Kotlin.
If no such version exists, report the issue to the plugin. If necessary, here is a guide on filing 
an issue against a plugin: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers#report-incompatible-kotlin-gradle-plugin-usage-to-plugin-authors

If you are a plugin author, please migrate your plugin to Built-in Kotlin using this guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors
Checking the license for package CMake 3.22.1 in /usr/local/lib/android/sdk/licenses
License for package CMake 3.22.1 accepted.
Preparing "Install CMake 3.22.1 v.3.22.1".
"Install CMake 3.22.1 v.3.22.1" ready.
Installing CMake 3.22.1 in /usr/local/lib/android/sdk/cmake/3.22.1
"Install CMake 3.22.1 v.3.22.1" complete.
"Install CMake 3.22.1 v.3.22.1" finished.
"de": 156 untranslated message(s).
"es": 496 untranslated message(s).
"es_ES": 156 untranslated message(s).
"fr": 156 untranslated message(s).
"id": 106 untranslated message(s).
"ja": 156 untranslated message(s).
"ko": 156 untranslated message(s).
"pt": 496 untranslated message(s).
"pt_PT": 156 untranslated message(s).
"ru": 156 untranslated message(s).
"tr": 156 untranslated message(s).
"uk": 156 untranslated message(s).
To see a detailed report, use the untranslated-messages-file 
option in the l10n.yaml file:
untranslated-messages-file: desiredFileName.txt
<other option>: <other selection> 


This will generate a JSON format file containing all messages that 
need to be translated.
Running Gradle task 'assembleDebug'...                            361.4s
✓ Built build/app/outputs/flutter-apk/app-debug.apk

## gradle :app:testDebugUnitTest
> Task :flutter_local_notifications:bundleLibRuntimeToJarDebug
> Task :flutter_local_notifications:processDebugJavaRes NO-SOURCE
> Task :flutter_secure_storage:bundleLibRuntimeToJarDebug
> Task :flutter_secure_storage:processDebugJavaRes NO-SOURCE
> Task :jni:processDebugJavaRes NO-SOURCE
> Task :jni:bundleLibRuntimeToJarDebug
> Task :jni_flutter:processDebugJavaRes NO-SOURCE
> Task :jni_flutter:bundleLibRuntimeToJarDebug
> Task :open_filex:processDebugJavaRes NO-SOURCE
> Task :open_filex:bundleLibRuntimeToJarDebug
> Task :permission_handler_android:processDebugJavaRes NO-SOURCE
> Task :permission_handler_android:bundleLibRuntimeToJarDebug
> Task :receive_sharing_intent:bundleLibRuntimeToJarDebug
> Task :receive_sharing_intent:processDebugJavaRes UP-TO-DATE
> Task :share_plus:processDebugJavaRes UP-TO-DATE
> Task :shared_preferences_android:processDebugJavaRes UP-TO-DATE
> Task :share_plus:bundleLibRuntimeToJarDebug
> Task :sqflite_android:processDebugJavaRes NO-SOURCE
> Task :sqflite_android:bundleLibRuntimeToJarDebug
> Task :shared_preferences_android:bundleLibRuntimeToJarDebug
> Task :url_launcher_android:bundleLibRuntimeToJarDebug
> Task :url_launcher_android:processDebugJavaRes UP-TO-DATE
> Task :video_player_android:processDebugJavaRes UP-TO-DATE
> Task :video_player_android:bundleLibRuntimeToJarDebug
> Task :app:compileDebugUnitTestKotlin
> Task :app:compileDebugUnitTestJavaWithJavac NO-SOURCE
> Task :app:processDebugUnitTestJavaRes
> Task :app:testDebugUnitTest
gradle/actions: Writing build results to /home/runner/work/_temp/.gradle-actions/build-results/__run_5-1788994006545.json

[Incubating] Problems report is available at: file:///home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/build/reports/problems/problems-report.html

Deprecated Gradle features were used in this build, making it incompatible with Gradle 10.

You can use '--warning-mode all' to show the individual deprecation warnings and determine if they come from your own scripts or plugins.

For more on this, please refer to https://docs.gradle.org/9.6.1/userguide/command_line_interface.html#sec:command_line_warnings in the Gradle documentation.

BUILD SUCCESSFUL in 36s
348 actionable tasks: 30 executed, 318 up-to-date

## APK output
total 355440
drwxr-xr-x 2 runner runner      4096 Sep  9 22:46 .
drwxr-xr-x 6 runner runner      4096 Sep  9 22:46 ..
-rw-r--r-- 1 runner runner 363950770 Sep  9 22:46 app-debug.apk
-rw-r--r-- 1 runner runner        40 Sep  9 22:46 app-debug.apk.sha1
