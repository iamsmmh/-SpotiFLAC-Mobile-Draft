import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';

void main() {
  group('coreCategoryForBackendError', () {
    test('maps typed backend errors', () {
      expect(
        coreCategoryForBackendError(errorType: 'permission'),
        CoreErrorCategory.permission,
      );
      expect(
        coreCategoryForBackendError(errorType: 'not_found'),
        CoreErrorCategory.notFound,
      );
      expect(
        coreCategoryForBackendError(errorType: 'rate_limit'),
        CoreErrorCategory.rateLimited,
      );
      expect(
        coreCategoryForBackendError(errorType: 'cancelled'),
        CoreErrorCategory.cancelled,
      );
      expect(
        coreCategoryForBackendError(errorType: 'write_failed'),
        CoreErrorCategory.storage,
      );
      expect(
        coreCategoryForBackendError(errorType: 'checksum'),
        CoreErrorCategory.integrity,
      );
    });

    test('maps message-only failures conservatively', () {
      expect(
        coreCategoryForBackendError(
          errorMessage: 'SAF permission invalid or revoked',
        ),
        CoreErrorCategory.permission,
      );
      expect(
        coreCategoryForBackendError(errorMessage: 'No space left on device'),
        CoreErrorCategory.storage,
      );
      expect(
        coreCategoryForBackendError(
          errorMessage: 'Connection timed out after 30s',
        ),
        CoreErrorCategory.network,
      );
      expect(
        coreCategoryForBackendError(errorMessage: 'HTTP 429 too many requests'),
        CoreErrorCategory.rateLimited,
      );
      expect(
        coreCategoryForBackendError(errorMessage: 'Track not found'),
        CoreErrorCategory.notFound,
      );
    });

    test('stays unknown for unrecognized shapes', () {
      expect(
        coreCategoryForBackendError(
          errorType: 'weird',
          errorMessage: 'xyzzy happened',
        ),
        CoreErrorCategory.unknown,
      );
      expect(coreCategoryForBackendError(), CoreErrorCategory.unknown);
    });
  });

  group('CoreError retryability', () {
    test('derives from category by default', () {
      expect(
        const CoreError(
          category: CoreErrorCategory.network,
          message: 'x',
        ).isRetryable,
        isTrue,
      );
      expect(
        const CoreError(
          category: CoreErrorCategory.permission,
          message: 'x',
        ).isRetryable,
        isFalse,
      );
      expect(
        const CoreError(
          category: CoreErrorCategory.integrity,
          message: 'x',
        ).isRetryable,
        isFalse,
      );
    });

    test('explicit override wins over the category default', () {
      expect(
        const CoreError(
          category: CoreErrorCategory.storage,
          message: 'x',
          retryable: true,
        ).isRetryable,
        isTrue,
      );
    });
  });

  group('normalizeCoreError', () {
    test('passes CoreError through untouched', () {
      const original = CoreError(
        category: CoreErrorCategory.storage,
        message: 'disk',
      );
      expect(identical(normalizeCoreError(original), original), isTrue);
    });

    test('attributes providerId when missing', () {
      const original = CoreError(
        category: CoreErrorCategory.provider,
        message: 'js error',
      );
      final normalized = normalizeCoreError(original, providerId: 'deezer');
      expect(normalized.providerId, 'deezer');
      expect(normalized.category, CoreErrorCategory.provider);
    });

    test('wraps foreign exceptions with the fallback category', () {
      final normalized = normalizeCoreError(
        StateError('bad state'),
        fallback: CoreErrorCategory.storage,
      );
      expect(normalized.category, CoreErrorCategory.storage);
      expect(normalized.message, contains('bad state'));
      expect(normalized.cause, isA<StateError>());
    });
  });

  group('ExtensionExhaustedError', () {
    CoreError failure(CoreErrorCategory category) =>
        CoreError(category: category, message: category.name);

    test('permission failures dominate the aggregate category', () {
      final error = ExtensionExhaustedError(
        failures: <CoreError>[
          failure(CoreErrorCategory.network),
          failure(CoreErrorCategory.permission),
        ],
        message: 'all failed',
      );
      expect(error.category, CoreErrorCategory.permission);
    });

    test('rate-limit dominates over other non-permission failures', () {
      final error = ExtensionExhaustedError(
        failures: <CoreError>[
          failure(CoreErrorCategory.network),
          failure(CoreErrorCategory.rateLimited),
        ],
        message: 'all failed',
      );
      expect(error.category, CoreErrorCategory.rateLimited);
    });

    test('is retryable when any provider failure was retryable', () {
      final error = ExtensionExhaustedError(
        failures: <CoreError>[
          failure(CoreErrorCategory.unknown),
          failure(CoreErrorCategory.network),
        ],
        message: 'all failed',
      );
      expect(error.isRetryable, isTrue);
    });

    test('keeps the immutable per-provider failure list', () {
      final failures = <CoreError>[failure(CoreErrorCategory.network)];
      final error = ExtensionExhaustedError(
        failures: failures,
        message: 'all failed',
      );
      failures.add(failure(CoreErrorCategory.storage));
      expect(error.failures, hasLength(1));
    });
  });
}
