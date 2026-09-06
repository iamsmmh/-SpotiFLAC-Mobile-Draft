/// Riverpod wiring for the stream cache module (Feature Group 7).
///
/// Providers are thin: they compose `ecosystem/cache/**` services and
/// expose immutable state, following the ecosystem-provider conventions.
/// The cache directory lives under the app cache dir (never the user's
/// music folder), and the at-rest key lives in the platform secure store.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:spotimusic/ecosystem/cache/cache_cleanup_worker.dart';
import 'package:spotimusic/ecosystem/cache/cache_index.dart';
import 'package:spotimusic/ecosystem/cache/cache_cipher.dart';
import 'package:spotimusic/ecosystem/cache/cache_repository.dart';
import 'package:spotimusic/ecosystem/cache/streaming_cache_manager.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/providers/provider_accounts_provider.dart'
    show secureStoreProvider;

/// Secret-store key holding the 64-hex-char ChaCha20 key.
const String streamCacheKeyName = 'stream_cache_key_v1';

final cacheRepositoryProvider = Provider<CacheRepository>((ref) {
  return CacheRepository(database: ref.watch(ecosystemDatabaseProvider));
});

/// Resolves `<appCache>/stream_cache` (created lazily by the manager).
Future<Directory> resolveStreamCacheDirectory() async {
  final base = await getApplicationCacheDirectory();
  return Directory('${base.path}/stream_cache');
}

final streamingCacheManagerProvider = Provider<StreamingCacheManager>((ref) {
  final manager = StreamingCacheManager(
    repository: ref.watch(cacheRepositoryProvider),
    storage: CacheStorage(resolveDirectory: resolveStreamCacheDirectory),
    client: http.Client(),
    encryptionEnabled: false,
    keyProvider: () async {
      final secure = ref.read(secureStoreProvider);
      var hex = await secure.readToken(streamCacheKeyName);
      if (hex == null || hex.length != 64) {
        final key = generateCacheKey();
        hex = _hexOf(key);
        await secure.writeToken(streamCacheKeyName, hex);
      }
      return _hexToBytes(hex);
    },
  );
  ref.onDispose(manager.disposeClient);
  // Best-effort eager index rebuild: without a platform database factory
  // (flutter test) or on a first run the hot index simply starts empty —
  // lookupPlayable repopulates lazily from the repository. A failure here
  // must never escape into the surrounding zone.
  unawaited(
    manager.refreshIndex().catchError((Object _) {
      // Intentionally swallowed; see comment above.
    }),
  );
  return manager;
});

final cacheCleanupWorkerProvider = Provider<CacheCleanupWorker>((ref) {
  return CacheCleanupWorker(
    repository: ref.watch(cacheRepositoryProvider),
    deleter: (fileName) async {
      final dir = await resolveStreamCacheDirectory();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        await file.delete();
      }
    },
  );
});

/// Hot index for instant lookups (kept fresh by the manager).
final streamCacheIndexProvider = Provider<CacheIndex>((ref) {
  final manager = ref.watch(streamingCacheManagerProvider);
  manager.refreshIndex();
  return manager.index;
});

/// Cache stats for the settings surface.
class StreamCacheStats {
  const StreamCacheStats({
    required this.entries,
    required this.totalBytes,
    required this.activeFetches,
  });

  final int entries;
  final int totalBytes;
  final int activeFetches;

  String get sizeLabel {
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = totalBytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

final streamCacheStatsProvider = FutureProvider<StreamCacheStats>((ref) async {
  final manager = ref.watch(streamingCacheManagerProvider);
  final repository = ref.watch(cacheRepositoryProvider);
  return StreamCacheStats(
    entries: await repository.count(),
    totalBytes: await repository.totalBytes(),
    activeFetches: manager.activeFetches.length,
  );
});

/// LRU budget derived from the existing engine cache-size setting (MiB).
int streamCacheBudgetBytes(int maxCacheSizeMb) =>
    maxCacheSizeMb <= 0 ? 2 * 1024 * 1024 * 1024 : maxCacheSizeMb * 1024 * 1024;

String _hexOf(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

List<int> _hexToBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) return const <int>[];
    out.add(byte);
  }
  return out;
}
