/// Production artifact naming, ABI splits, and SHA-256 verification.
///
/// The GitHub Actions release workflow is the source of the on-disk files;
/// this policy is the source of the *names and hashes* so a drifted workflow
/// fails the Dart suite instead of shipping a silently misnamed APK.
library;

import 'package:spotiflac_android/core/data/sha256.dart';

class ReleaseArtifact {
  const ReleaseArtifact({
    required this.fileName,
    required this.platform,
    required this.abi,
    required this.kind,
  });

  final String fileName;
  final String platform;
  final String abi;
  final String kind;
}

abstract final class ReleaseArtifactPolicy {
  static const String appName = 'SpotiFLAC';

  /// Android ABI splits required for the v1.0 production channel.
  static const List<String> androidAbis = <String>[
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
  ];

  /// Flutter `--target-platform` flags matching [androidAbis].
  static const List<String> flutterTargetPlatforms = <String>[
    'android-arm64',
    'android-arm',
    'android-x64',
  ];

  /// gomobile `-target` triples matching [androidAbis].
  static const String gomobileAndroidTarget =
      'android/arm,android/arm64,android/amd64';

  static const String androidApiLevel = '24';

  static String apkFileName(String version, String abiAlias) =>
      '$appName-$version-$abiAlias.apk';

  static String aabFileName(String version) => '$appName-$version.aab';

  static String ipaFileName(String version, {bool unsigned = true}) {
    final suffix = unsigned ? '-ios-unsigned' : '-ios';
    return '$appName-$version$suffix.ipa';
  }

  static String checksumFileName() => 'SHA256SUMS.txt';

  /// ABI alias used in the published file name.
  static String abiAlias(String abi) => switch (abi) {
    'arm64-v8a' => 'arm64',
    'armeabi-v7a' => 'arm32',
    'x86_64' => 'x86_64',
    _ => abi,
  };

  static List<ReleaseArtifact> expectedArtifacts(
    String version, {
    bool includeAab = true,
    bool includeIos = true,
  }) {
    final artifacts = <ReleaseArtifact>[
      for (final abi in androidAbis)
        ReleaseArtifact(
          fileName: apkFileName(version, abiAlias(abi)),
          platform: 'android',
          abi: abi,
          kind: 'apk',
        ),
    ];
    if (includeAab) {
      artifacts.add(
        ReleaseArtifact(
          fileName: aabFileName(version),
          platform: 'android',
          abi: 'universal',
          kind: 'aab',
        ),
      );
    }
    if (includeIos) {
      artifacts.add(
        ReleaseArtifact(
          fileName: ipaFileName(version),
          platform: 'ios',
          abi: 'arm64',
          kind: 'ipa',
        ),
      );
    }
    return artifacts;
  }

  /// `sha256sum`-compatible line: `<hex>  <filename>`.
  static String checksumLine(String fileName, List<int> bytes) {
    return '${sha256Hex(bytes)}  $fileName';
  }

  /// Parse a SHA256SUMS.txt body into `{fileName: hex}`. Throws
  /// [FormatException] on a malformed line so a broken release script fails
  /// the suite instead of shipping an unverifiable artifact.
  static Map<String, String> parseChecksums(String body) {
    final out = <String, String>{};
    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = _checksumLine.firstMatch(line);
      if (match == null) {
        throw FormatException('Invalid SHA-256 checksum line: $line');
      }
      out[match.group(2)!] = match.group(1)!.toLowerCase();
    }
    return out;
  }

  static bool verify({
    required String fileName,
    required List<int> bytes,
    required Map<String, String> checksums,
  }) {
    final expected = checksums[fileName];
    if (expected == null) return false;
    return expected == sha256Hex(bytes);
  }

  static final RegExp _checksumLine = RegExp(
    r'^([0-9a-fA-F]{64}) [ *](.+)$',
  );
}
