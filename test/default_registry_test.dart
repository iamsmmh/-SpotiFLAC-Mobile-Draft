import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/providers/repo_provider.dart';
import 'package:spotiflac_android/screens/setup_extensions_step.dart';
import 'package:spotiflac_android/utils/user_facing_error.dart';

void main() {
  group('default extension registry', () {
    test('points at the official registry over HTTPS', () {
      final uri = Uri.parse(AppInfo.defaultRegistryUrl);
      expect(uri.isScheme('HTTPS'), isTrue);
      expect(uri.host, 'raw.githubusercontent.com');
      expect(uri.path.endsWith('/registry.json'), isTrue);
      expect(AppInfo.defaultRegistryName.isNotEmpty, isTrue);
    });

    test('recommended set is non-empty, unique and id-shaped', () {
      expect(recommendedExtensionIds.isNotEmpty, isTrue);
      expect(
        recommendedExtensionIds.toSet().length,
        recommendedExtensionIds.length,
      );
      final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');
      for (final id in recommendedExtensionIds) {
        expect(idPattern.hasMatch(id), isTrue, reason: 'id: $id');
      }
    });

    test('RepoState distinguishes default from custom registries', () {
      expect(const RepoState().hasRegistryUrl, isFalse);
      expect(const RepoState().isDefaultRegistry, isFalse);

      final custom = const RepoState().copyWith(
        registryUrl: 'https://example.test/registry.json',
      );
      expect(custom.hasRegistryUrl, isTrue);
      expect(custom.isDefaultRegistry, isFalse);

      final def = const RepoState().copyWith(
        registryUrl: AppInfo.defaultRegistryUrl,
      );
      expect(def.hasRegistryUrl, isTrue);
      expect(def.isDefaultRegistry, isTrue);
    });

    test('RecommendedInstallResult reports readiness', () {
      expect(
        const RecommendedInstallResult(
          installed: <String>['a'],
          alreadyPresent: <String>['b'],
        ).allReady,
        isTrue,
      );
      expect(
        const RecommendedInstallResult(
          failed: <String>['a'],
        ).allReady,
        isFalse,
      );
      expect(
        const RecommendedInstallResult(
          unavailable: <String>['a'],
        ).allReady,
        isFalse,
      );
    });

    test('setup result summary counts every bucket', () {
      final summary = summarizeRecommendedInstall(
        const RecommendedInstallResult(
          installed: <String>['a'],
          alreadyPresent: <String>['b', 'c'],
          unavailable: <String>['d'],
          failed: <String>['e'],
        ),
      );
      expect(summary, contains('3/5 ready'));
      expect(summary, contains('new: 1'));
      expect(summary, contains('kept: 2'));
      expect(summary, contains('missing: 1'));
      expect(summary, contains('failed: 1'));
    });
  });

  group('isMissingDownloadProviderError', () {
    test('matches the backend retired-provider error', () {
      expect(
        isMissingDownloadProviderError(
          'Extension providers are disabled; built-in download providers '
          'have been retired',
        ),
        isTrue,
      );
    });

    test('matches case-insensitively and inside wrappers', () {
      expect(
        isMissingDownloadProviderError(
          'Exception: NO ENABLED DOWNLOAD PROVIDER for this item',
        ),
        isTrue,
      );
      expect(isMissingDownloadProviderError('No download provider'), isTrue);
    });

    test('does not match unrelated failures', () {
      expect(isMissingDownloadProviderError('Song not found'), isFalse);
      expect(isMissingDownloadProviderError(''), isFalse);
      expect(
        isMissingDownloadProviderError('The request timed out.'),
        isFalse,
      );
      expect(
        isMissingDownloadProviderError('Network is unreachable'),
        isFalse,
      );
    });
  });
}
