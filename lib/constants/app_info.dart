import 'package:flutter/foundation.dart';
import 'package:spotiflac_android/core/data/release_artifact_policy.dart';

class AppInfo {
  static const String version = '5.0.0';
  static const String buildNumber = '142';
  static const String fullVersion = '$version+$buildNumber';

  static String get displayVersion => kDebugMode ? 'Internal' : version;

  static const String appName = 'SpotiFLAC Mobile';

  /// Prefix used by the production release workflow (`SpotiFLAC-<ver>-arm64.apk`).
  static const String releaseArtifactPrefix = ReleaseArtifactPolicy.appName;

  /// Android ABI splits the production channel must publish.
  static const List<String> productionAndroidAbis =
      ReleaseArtifactPolicy.androidAbis;
  static const String copyright = '© 2026 Zarz Eleutherius';

  static const String mobileAuthor = 'zarzet';
  static const String originalAuthor = 'afkarxyz';

  static const String githubRepo = 'spotiflacapp/SpotiFLAC-Mobile';
  static const String githubUrl = 'https://github.com/$githubRepo';
  static const String originalGithubUrl =
      'https://github.com/afkarxyz/SpotiFLAC';
  static const String remoteConfigApiUrl =
      'https://api.zarz.moe/v1/spotiflac-mobile/config';

  /// Official community extension registry, pre-configured on first launch so
  /// a fresh install can reach the Store without pasting a URL. Users can
  /// replace or remove it at any time (Store → link icon); the decentralized
  /// model is unchanged, this is only the default.
  static const String defaultRegistryUrl =
      'https://raw.githubusercontent.com/spotiflacapp/SpotiFLAC-Extension/main/registry.json';
  static const String defaultRegistryName = 'Official SpotiFLAC registry';

  static const String kofiUrl = 'https://ko-fi.com/zarzet';
  static const String githubSponsorsUrl = 'https://github.com/sponsors/zarzet/';
}
