/// Streaming cache manager (Feature Group 7) — cache-while-listening.
///
/// Fetches an already-resolved stream URL into the cache directory *in
/// parallel with playback*: the player keeps streaming from the network
/// (the verified `UrlSource` pipeline is untouched — the deferred proxy
/// design in ARCHITECTURE.md stays deferred), while this manager writes
/// the same bytes to a staged file, digests them (SHA-256), optionally
/// encrypts them at rest (ChaCha20, key in the secure store) and commits
/// atomically. On the next play of the same logical track the cache is
/// consulted *first*, giving instant start and offline replay.
///
/// Integrity: staged bytes are digested while streaming; the digest is
/// re-verified before a cached file is swapped into live playback
/// (hybrid path) and on explicit [verifyEntry] calls. LRU eviction runs
/// through [CacheCleanupWorker].
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_cipher.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_cleanup_worker.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_index.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_models.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_repository.dart';

/// Injected filesystem layout (production: path_provider-backed; tests:
/// temp dirs or fakes).
class CacheStorage {
  const CacheStorage({required this.resolveDirectory});

  final Future<Directory> Function() resolveDirectory;

  Future<String> filePathFor(String fileName) async {
    final dir = await resolveDirectory();
    return '${dir.path}/$fileName';
  }
}

/// Supplies the at-rest encryption key (32 bytes) or null to disable
/// encryption. Production binds to the platform secure store.
typedef CacheKeyProvider = Future<List<int>?> Function();

/// Live fetch accounting.
class CacheFetchProgress {
  const CacheFetchProgress({
    required this.trackKey,
    required this.bytesWritten,
    required this.totalBytes,
  });

  final String trackKey;
  final int bytesWritten;
  final int? totalBytes;

  double get fraction {
    final total = totalBytes ?? 0;
    if (total <= 0) return 0;
    return (bytesWritten / total).clamp(0.0, 1.0);
  }
}

/// Outcome of one background fetch.
class CacheFetchResult {
  const CacheFetchResult({
    required this.trackKey,
    required this.entry,
    required this.status,
    this.error,
  });

  final String trackKey;
  final CacheEntry? entry;
  final CacheFetchStatus status;
  final String? error;
}

enum CacheFetchStatus { completed, skipped, failed, cancelled }

/// The manager. One instance per app (Riverpod-owned).
class StreamingCacheManager {
  StreamingCacheManager({
    required this.repository,
    required this.storage,
    required http.Client client,
    this.encryptionEnabled = false,
    CacheKeyProvider? keyProvider,
    this.maxArtifactBytes = 1024 * 1024 * 1024,
    this.chunkBytes = 256 * 1024,
    DateTime Function()? clock,
  }) : _client = client,
       _keyProvider = keyProvider,
       _clock = clock ?? DateTime.now {
    if (maxArtifactBytes < 1024) maxArtifactBytes = 1024;
  }

  final CacheRepository repository;
  final CacheStorage storage;
  final http.Client _client;
  final CacheKeyProvider? _keyProvider;
  final DateTime Function() _clock;

  /// Hard cap for one artifact (default 1 GiB — FLAC albums included).
  int maxArtifactBytes;

  /// Streaming write granularity (default 256 KiB).
  final int chunkBytes;

  /// Master switch for at-rest encryption.
  bool encryptionEnabled;

  final Set<String> _activeTrackKeys = <String>{};
  final Set<String> _cancelled = <String>{};
  final Map<String, String> _decryptedTemps = <String, String>{};
  CacheIndex _index = CacheIndex.empty();

  CacheIndex get index => _index;

  Set<String> get activeFetches => Set<String>.unmodifiable(_activeTrackKeys);

  /// Rebuilds the hot index from the repository (app start, post-eviction).
  Future<void> refreshIndex() async {
    _index = CacheIndex(await repository.all());
  }

  /// Instant lookup used by the playback path before any network work.
  Future<CacheHit?> lookupPlayable(String trackKey) async {
    final entry = _index.playableForTrack(trackKey);
    if (entry == null) {
      final fetched = await repository.playableForTrack(trackKey);
      if (fetched == null) return null;
      await refreshIndex();
      return _hitFor(fetched);
    }
    return _hitFor(entry);
  }

  Future<CacheHit?> _hitFor(CacheEntry entry) async {
    final path = await _playablePathFor(entry);
    if (path == null) return null;
    unawaited(repository.touch(entry.cacheKey, at: _clock()));
    return CacheHit(entry: entry.copyWith(accessCount: entry.accessCount + 1), filePath: path);
  }

  /// Resolves a *plaintext* playable path: encrypted entries are decrypted
  /// into a managed temp file (swept by [sweepDecryptedTemps]).
  Future<String?> _playablePathFor(CacheEntry entry) async {
    final path = await storage.filePathFor(entry.fileName);
    if (!entry.encrypted) {
      if (!await File(path).exists()) return null;
      return path;
    }
    final existing = _decryptedTemps[entry.cacheKey];
    if (existing != null && await File(existing).exists()) return existing;
    final cipher = await _cipherFor(entry);
    if (cipher == null) return null;
    final encrypted = await File(path).exists()
        ? await File(path).readAsBytes()
        : null;
    if (encrypted == null || encrypted.isEmpty) return null;
    final plain = cipher.processBytes(encrypted);
    final temp = File('$path.play');
    await temp.writeAsBytes(plain, flush: true);
    _decryptedTemps[entry.cacheKey] = temp.path;
    return temp.path;
  }

  Future<ChaCha20?> _cipherFor(CacheEntry entry) async {
    final key = await _keyProvider?.call();
    if (key == null || key.length != 32) return null;
    final nonce = hexToBytes(entry.ivHex);
    if (nonce.length != 12) return null;
    return ChaCha20(key: key, nonce: nonce);
  }

  /// Starts a background fetch for [request]. Returns a future that
  /// completes with the outcome; playback never awaits it.
  Future<CacheFetchResult> startFetch(CacheFetchRequest request) async {
    if (_activeTrackKeys.contains(request.trackKey)) {
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.skipped,
        error: 'already fetching',
      );
    }
    if (_index.playableForTrack(request.trackKey) != null) {
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.skipped,
        error: 'already cached',
      );
    }
    _activeTrackKeys.add(request.trackKey);
    _cancelled.remove(request.trackKey);
    try {
      return await _fetch(request);
    } finally {
      _activeTrackKeys.remove(request.trackKey);
    }
  }

  void cancelFetch(String trackKey) => _cancelled.add(trackKey);

  /// Closes the HTTP client (Riverpod disposal).
  void disposeClient() {
    _client.close();
  }

  Future<CacheFetchResult> _fetch(CacheFetchRequest request) async {
    final dir = await storage.resolveDirectory();
    await dir.create(recursive: true);

    final cacheKey = _cacheKeyFor(request);
    final stagedName = '$cacheKey.part';
    final stagedPath = await storage.filePathFor(stagedName);
    final digest = Sha256Accumulator();
    var written = 0;
    var format = request.formatHint;

    final http.StreamedResponse response;
    try {
      final parsed = http.Request('GET', Uri.parse(request.url))
        ..headers.addAll(<String, String>{
          'Accept': '*/*',
          ...request.headers,
        });
      response = await _client.send(parsed);
    } catch (error) {
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.failed,
        error: 'request failed: $error',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.failed,
        error: 'HTTP ${response.statusCode}',
      );
    }

    final sink = File(stagedPath).openWrite();
    List<int>? nonce;
    List<int>? encryptionKey;
    if (encryptionEnabled) {
      encryptionKey = await _keyProvider?.call();
      if (encryptionKey != null && encryptionKey.length == 32) {
        nonce = generateCacheNonce();
      } else {
        encryptionKey = null;
      }
    }
    final cipher = (encryptionKey != null && nonce != null)
        ? ChaCha20(key: encryptionKey, nonce: nonce)
        : null;

    try {
      var byteOffset = 0;
      await for (final chunk in response.stream) {
        if (_cancelled.contains(request.trackKey)) {
          await sink.close();
          await _deleteQuietly(stagedPath);
          return CacheFetchResult(
            trackKey: request.trackKey,
            entry: null,
            status: CacheFetchStatus.cancelled,
          );
        }
        if (byteOffset == 0) {
          final sniffed = CachedAudioFormat.sniff(chunk);
          if (sniffed != CachedAudioFormat.unknown) format = sniffed;
        }
        digest.add(chunk);
        final out = cipher == null
            ? chunk
            : cipher.processBytes(chunk, initialCounter: byteOffset ~/ 64);
        sink.add(out);
        byteOffset += chunk.length;
        if (byteOffset > maxArtifactBytes) {
          await sink.close();
          await _deleteQuietly(stagedPath);
          return CacheFetchResult(
            trackKey: request.trackKey,
            entry: null,
            status: CacheFetchStatus.failed,
            error: 'exceeds cache budget ($maxArtifactBytes bytes)',
          );
        }
      }
      written = byteOffset;
      await sink.flush();
      await sink.close();
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {
        // Closing an already-broken sink is best-effort.
      }
      await _deleteQuietly(stagedPath);
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.failed,
        error: 'write failed: $error',
      );
    }

    if (written <= 0) {
      await _deleteQuietly(stagedPath);
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.failed,
        error: 'empty body',
      );
    }

    final resolvedFormat = format ??
        CachedAudioFormat.fromCodecLabel(response.headers['content-type']);
    final finalName = '$cacheKey.${resolvedFormat.fileExtension}';
    final finalPath = await storage.filePathFor(finalName);
    try {
      final staged = File(stagedPath);
      await staged.rename(finalPath);
    } catch (_) {
      await _deleteQuietly(stagedPath);
      return CacheFetchResult(
        trackKey: request.trackKey,
        entry: null,
        status: CacheFetchStatus.failed,
        error: 'commit failed',
      );
    }

    final entry = CacheEntry(
      cacheKey: cacheKey,
      trackKey: request.trackKey,
      title: request.title,
      artist: request.artist,
      fileName: finalName,
      audioFormat: resolvedFormat,
      bytes: written,
      durationMs: request.durationMs,
      sourceUrl: request.sourceUrl ?? request.url,
      createdAt: _clock(),
      lastAccessedAt: _clock(),
      complete: true,
      sha256: digest.digestHex(),
      encrypted: cipher != null,
      ivHex: nonce == null ? '' : bytesToHex(nonce),
    );
    await repository.upsertPartial(entry);
    await refreshIndex();
    return CacheFetchResult(
      trackKey: request.trackKey,
      entry: entry,
      status: CacheFetchStatus.completed,
    );
  }

  /// Re-reads a stored artifact and re-verifies its digest.
  Future<bool> verifyEntry(CacheEntry entry) async {
    if (!entry.complete || entry.sha256.isEmpty) return false;
    try {
      final path = await storage.filePathFor(entry.fileName);
      final bytes = await File(path).readAsBytes();
      final digest = Sha256Accumulator()..add(bytes);
      return digest.digestHex() == entry.sha256;
    } catch (_) {
      return false;
    }
  }

  /// Full verification of an encrypted entry: decrypt then digest.
  Future<bool> verifyEncryptedEntry(CacheEntry entry) async {
    if (!entry.complete || entry.sha256.isEmpty || !entry.encrypted) {
      return false;
    }
    final cipher = await _cipherFor(entry);
    if (cipher == null) return false;
    try {
      final path = await storage.filePathFor(entry.fileName);
      final bytes = await File(path).readAsBytes();
      final plain = cipher.processBytes(bytes);
      final digest = Sha256Accumulator()..add(plain);
      return digest.digestHex() == entry.sha256;
    } catch (_) {
      return false;
    }
  }

  /// Removes a track's cache (row + file). Returns whether anything was
  /// removed.
  Future<bool> evictTrack(String trackKey) async {
    final entries = await repository.allForTrack(trackKey);
    if (entries.isEmpty) return false;
    await repository.deleteForTrack(trackKey);
    for (final entry in entries) {
      await _deleteQuietly(await storage.filePathFor(entry.fileName));
      await _deleteQuietly('${await storage.filePathFor(entry.fileName)}.play');
    }
    await refreshIndex();
    return true;
  }

  Future<void> setPinned(String trackKey, bool pinned) async {
    final entries = await repository.allForTrack(trackKey);
    for (final entry in entries) {
      await repository.setPinned(entry.cacheKey, pinned);
    }
    await refreshIndex();
  }

  /// Sweeps decrypted playback temps (called on player stop).
  Future<void> sweepDecryptedTemps() async {
    for (final path in _decryptedTemps.values) {
      await _deleteQuietly(path);
    }
    _decryptedTemps.clear();
  }

  /// Deletes orphaned `*.part`/`*.play` files older than [olderThan].
  Future<int> sweepOrphans({Duration olderThan = const Duration(hours: 6)}) async {
    final dir = await storage.resolveDirectory();
    if (!await dir.exists()) return 0;
    var removed = 0;
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.part') && !name.endsWith('.play')) continue;
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        try {
          await entity.delete();
          removed += 1;
        } catch (_) {
          // Best-effort.
        }
      }
    }
    return removed;
  }

  String _cacheKeyFor(CacheFetchRequest request) {
    // Deterministic per (track, url): re-fetches of the same URL replace
    // the artifact; a different quality for the same track gets a sibling
    // key (the playable lookup always prefers the newest).
    final raw = '${request.trackKey}|${request.url}';
    final digest = Sha256Accumulator()..add(raw.codeUnits);
    return digest.digestHex().substring(0, 24);
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort by design.
    }
  }
}
