/// Smart cache playback source for the unified playback layer.
///
/// [PlaybackCacheManager] stores previously-streamed audio (plus artwork and
/// per-track metadata) under the app cache directory so repeat plays start
/// instantly and survive offline gaps:
///
///   ```text
///   <root>/
///     tracks/     cached audio bytes (<key>.<ext>)
///     artwork/    cached cover bytes (<key>.<ext>)
///     metadata/   per-track JSON index (<key>.json)
///     tmp/        in-flight writes (swept by maintenance)
///   ```
///
/// Eviction is LRU with a configurable byte budget; pinned entries (favorites
/// and manual caches) are never evicted automatically. Recently/frequently
/// played signals come from access-time and play-count tracking on every
/// lookup.
///
/// [CachePlaybackSource] plays verified cache hits on the shared player. This
/// cache complements the ecosystem's encrypted stream cache (which owns
/// provider-terms-gated caching); entries here are only written when the
/// manager was told caching is permitted for the source.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:spotiflac_android/engine/track_identity.dart'
    show CanonicalTrackKey, TrackIdentityInput;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback_source.dart';

/// Stable, filesystem-safe cache key for [track].
///
/// Reuses the canonical track identity (ISRC when known, otherwise the
/// normalized title/artist/duration fingerprint), so the same work found
/// through different providers maps to one cache entry.
String playbackCacheKeyForTrack(Track track) {
  try {
    return CanonicalTrackKey.fromInput(
      TrackIdentityInput.fromTrack(track),
    ).stableId;
  } catch (_) {
    final sanitized = track.id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    return 'fb-${track.id.length}-$sanitized';
  }
}

/// Durable per-track cache record (one `<key>.json` in `metadata/`).
class PlaybackCacheEntry {
  const PlaybackCacheEntry({
    required this.key,
    required this.trackId,
    this.title = '',
    this.artist = '',
    this.bytes = 0,
    this.format = '',
    this.fileName = '',
    this.artworkFileName,
    required this.createdAt,
    required this.lastAccessAt,
    this.playCount = 0,
    this.pinned = false,
  });

  final String key;
  final String trackId;
  final String title;
  final String artist;

  /// Audio payload size in bytes (used for budget accounting).
  final int bytes;

  /// Container/codec label as stored (e.g. `FLAC`, `MP3`); may be empty.
  final String format;

  /// Audio file name inside `tracks/` (key + extension).
  final String fileName;

  /// Artwork file name inside `artwork/`; null when no artwork is cached.
  final String? artworkFileName;

  final DateTime createdAt;
  final DateTime lastAccessAt;
  final int playCount;

  /// Favorites and manual caches: never evicted automatically.
  final bool pinned;

  PlaybackCacheEntry copyWith({
    int? bytes,
    String? format,
    String? fileName,
    String? artworkFileName,
    DateTime? lastAccessAt,
    int? playCount,
    bool? pinned,
  }) => PlaybackCacheEntry(
    key: key,
    trackId: trackId,
    title: title,
    artist: artist,
    bytes: bytes ?? this.bytes,
    format: format ?? this.format,
    fileName: fileName ?? this.fileName,
    artworkFileName: artworkFileName ?? this.artworkFileName,
    createdAt: createdAt,
    lastAccessAt: lastAccessAt ?? this.lastAccessAt,
    playCount: playCount ?? this.playCount,
    pinned: pinned ?? this.pinned,
  );

  /// Returns a copy recording one access at [now] (LRU touch + play count).
  PlaybackCacheEntry withPlay(DateTime now) => copyWith(
    lastAccessAt: now,
    playCount: playCount + 1,
  );

  /// Returns a copy recording recency at [now] without a play count bump.
  PlaybackCacheEntry touched(DateTime now) => copyWith(lastAccessAt: now);

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'track_id': trackId,
    'title': title,
    'artist': artist,
    'bytes': bytes,
    'format': format,
    'file_name': fileName,
    if (artworkFileName != null) 'artwork_file_name': artworkFileName,
    'created_at': createdAt.toUtc().toIso8601String(),
    'last_access_at': lastAccessAt.toUtc().toIso8601String(),
    'play_count': playCount,
    'pinned': pinned,
  };

  /// Strict parse: null when the record is structurally invalid. Unparsable
  /// timestamps degrade to the epoch so corrupt records evict first instead
  /// of poisoning the index.
  static PlaybackCacheEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final key = map['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    DateTime dateOf(Object? value) =>
        DateTime.tryParse(value?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return PlaybackCacheEntry(
      key: key,
      trackId: map['track_id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      format: map['format']?.toString() ?? '',
      fileName: map['file_name']?.toString() ?? '$key.bin',
      artworkFileName: map['artwork_file_name']?.toString(),
      createdAt: dateOf(map['created_at']),
      lastAccessAt: dateOf(map['last_access_at']),
      playCount: (map['play_count'] as num?)?.toInt() ?? 0,
      pinned: map['pinned'] == true,
    );
  }
}

/// A verified cache hit: the record plus absolute file paths.
class PlaybackCacheHit {
  const PlaybackCacheHit({
    required this.entry,
    required this.filePath,
    this.artworkPath,
  });

  final PlaybackCacheEntry entry;
  final String filePath;
  final String? artworkPath;
}

/// Outcome of one [PlaybackCacheManager.maintenance] pass.
class PlaybackCacheMaintenanceReport {
  const PlaybackCacheMaintenanceReport({
    required this.evictedKeys,
    required this.freedBytes,
    required this.totalBytes,
    required this.entryCount,
    required this.prunedTmpFiles,
  });

  /// Keys evicted by budget enforcement (LRU order).
  final List<String> evictedKeys;
  final int freedBytes;

  /// Total cached audio bytes after the pass.
  final int totalBytes;
  final int entryCount;
  final int prunedTmpFiles;

  @override
  String toString() =>
      'PlaybackCacheMaintenanceReport(evicted=${evictedKeys.length}, '
      'freed=$freedBytes B, total=$totalBytes B, entries=$entryCount, '
      'prunedTmp=$prunedTmpFiles)';
}

/// Downloads raw bytes for [uri] (full GET in production). Null/empty means
/// "could not fetch"; the entry is never stored partially.
typedef PlaybackCacheDownloader = Future<List<int>?> Function(Uri uri);

/// File-backed LRU audio cache with a configurable byte budget.
class PlaybackCacheManager {
  PlaybackCacheManager({
    required Future<Directory> Function() resolveRoot,
    int maxSizeBytes = defaultMaxCacheBytes,
    DateTime Function()? clock,
  }) : _resolveRoot = resolveRoot,
       _maxSizeBytes = maxSizeBytes < 0 ? 0 : maxSizeBytes,
       _clock = clock ?? DateTime.now;

  /// Fixed-root shorthand for tests and single-directory deployments.
  factory PlaybackCacheManager.atRoot(
    Directory root, {
    int maxSizeBytes = defaultMaxCacheBytes,
    DateTime Function()? clock,
  }) {
    return PlaybackCacheManager(
      resolveRoot: () async => root,
      maxSizeBytes: maxSizeBytes,
      clock: clock,
    );
  }

  static const int defaultMaxCacheBytes = 512 * 1024 * 1024;
  static const String tracksDirName = 'tracks';
  static const String artworkDirName = 'artwork';
  static const String metadataDirName = 'metadata';
  static const String tmpDirName = 'tmp';

  /// In-flight writes older than this are considered abandoned.
  static const Duration tmpPruneAge = Duration(hours: 1);

  final Future<Directory> Function() _resolveRoot;
  final DateTime Function() _clock;
  int _maxSizeBytes;
  Directory? _root;

  /// Maximum cached audio bytes. 0 (or negative, normalized to 0) means
  /// unlimited. Lowering the budget triggers budget enforcement.
  int get maxSizeBytes => _maxSizeBytes;

  set maxSizeBytes(int value) {
    _maxSizeBytes = value < 0 ? 0 : value;
    unawaited(_enforceBudget().catchError((Object _) {
      // Best-effort: the next lookup/store/maintenance pass retries.
      return const <String>[];
    }));
  }

  Future<Directory> _dir() async {
    final cached = _root;
    if (cached != null) return cached;
    final root = await _resolveRoot();
    _root = root;
    return root;
  }

  Future<Directory> _sub(String name) async {
    final root = await _dir();
    return Directory('${root.path}/$name');
  }

  /// Creates the `tracks/`/`artwork/`/`metadata/`/`tmp/` layout (idempotent).
  Future<void> ensureLayout() async {
    for (final name in const <String>[
      tracksDirName,
      artworkDirName,
      metadataDirName,
      tmpDirName,
    ]) {
      final dir = await _sub(name);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  /// Looks up a verified hit for [track] (null on miss or stale record).
  ///
  /// Stale records (metadata without audio bytes, corrupt JSON) are removed
  /// as encountered so they can never poison future lookups. Hits refresh
  /// recency (LRU touch) but not the play count — see [registerPlay].
  Future<PlaybackCacheHit?> lookup(Track track) {
    return lookupByKey(playbackCacheKeyForTrack(track));
  }

  Future<PlaybackCacheHit?> lookupByKey(String key) async {
    if (key.isEmpty) return null;
    final entry = await _readEntry(key);
    if (entry == null) return null;
    final tracks = await _sub(tracksDirName);
    final file = File('${tracks.path}/${entry.fileName}');
    if (!await file.exists()) {
      await evictByKey(key);
      return null;
    }
    final touched = entry.touched(_clock());
    await _writeEntry(touched);
    final artwork = entry.artworkFileName;
    String? artworkPath;
    if (artwork != null && artwork.isNotEmpty) {
      final dir = await _sub(artworkDirName);
      final candidate = File('${dir.path}/$artwork');
      if (await candidate.exists()) artworkPath = candidate.path;
    }
    return PlaybackCacheHit(
      entry: touched,
      filePath: file.path,
      artworkPath: artworkPath,
    );
  }

  Future<bool> contains(Track track) async {
    return await lookup(track) != null;
  }

  /// Stores raw audio [bytes] for [track] (atomic tmp-write + rename).
  Future<PlaybackCacheHit> storeBytes({
    required Track track,
    required List<int> bytes,
    String? format,
    List<int>? artworkBytes,
  }) async {
    await ensureLayout();
    final key = playbackCacheKeyForTrack(track);
    final extension = _audioExtensionFor(format, bytes);
    final fileName = '$key$extension';
    final tmp = await _sub(tmpDirName);
    final staging = File(
      '${tmp.path}/$key-${_clock().microsecondsSinceEpoch}.part',
    );
    await staging.writeAsBytes(bytes, flush: true);
    final tracks = await _sub(tracksDirName);
    final target = File('${tracks.path}/$fileName');
    if (await target.exists()) {
      await target.delete();
    }
    await staging.rename(target.path);

    String? artworkFileName;
    if (artworkBytes != null && artworkBytes.isNotEmpty) {
      artworkFileName = await _storeArtwork(key, artworkBytes);
    } else {
      // A re-store without artwork keeps the previously cached cover.
      artworkFileName = (await _readEntry(key))?.artworkFileName;
    }

    final now = _clock();
    final previous = await _readEntry(key);
    final entry = PlaybackCacheEntry(
      key: key,
      trackId: track.id,
      title: track.name,
      artist: track.artistName,
      bytes: bytes.length,
      format: (format ?? '').trim().toUpperCase(),
      fileName: fileName,
      artworkFileName: artworkFileName,
      createdAt: previous?.createdAt ?? now,
      lastAccessAt: now,
      playCount: previous?.playCount ?? 0,
      pinned: previous?.pinned ?? false,
    );
    await _writeEntry(entry);
    await _enforceBudget();
    return PlaybackCacheHit(
      entry: entry,
      filePath: target.path,
      artworkPath: await _artworkPathOf(entry),
    );
  }

  /// Copies an on-disk [source] file into the cache for [track].
  Future<PlaybackCacheHit> storeFile({
    required Track track,
    required File source,
    String? format,
    List<int>? artworkBytes,
  }) async {
    final bytes = await source.readAsBytes();
    return storeBytes(
      track: track,
      bytes: bytes,
      format: format,
      artworkBytes: artworkBytes,
    );
  }

  /// Fetches [url] through [download] and stores the bytes for [track].
  ///
  /// Returns null (without storing anything) when the fetch fails or yields
  /// no bytes. Callers must only invoke this when the stream's provider
  /// terms permit caching.
  Future<PlaybackCacheHit?> fetchAndStore({
    required Track track,
    required String url,
    required PlaybackCacheDownloader download,
    String? format,
    List<int>? artworkBytes,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return null;
    List<int>? bytes;
    try {
      bytes = await download(uri);
    } catch (_) {
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return await storeBytes(
        track: track,
        bytes: bytes,
        format: format,
        artworkBytes: artworkBytes,
      );
    } catch (_) {
      await evict(track);
      return null;
    }
  }

  /// Records one play of [track] (recency + frequency signals).
  Future<void> registerPlay(Track track) async {
    final key = playbackCacheKeyForTrack(track);
    final entry = await _readEntry(key);
    if (entry == null) return;
    await _writeEntry(entry.withPlay(_clock()));
  }

  /// Pins ([pinned] = favorites/manual) or unpins [track].
  Future<void> setPinned(Track track, {required bool pinned}) async {
    final key = playbackCacheKeyForTrack(track);
    final entry = await _readEntry(key);
    if (entry == null) return;
    if (entry.pinned == pinned) return;
    await _writeEntry(entry.copyWith(pinned: pinned));
  }

  Future<void> evict(Track track) {
    return evictByKey(playbackCacheKeyForTrack(track));
  }

  /// Removes every cached artifact for [key] (best-effort per file).
  Future<void> evictByKey(String key) async {
    if (key.isEmpty) return;
    final entry = await _readEntry(key);
    final tracks = await _sub(tracksDirName);
    final metadata = await _sub(metadataDirName);
    final artwork = await _sub(artworkDirName);
    final targets = <File>[
      if (entry != null) File('${tracks.path}/${entry.fileName}'),
      File('${metadata.path}/$key.json'),
      if (entry?.artworkFileName != null)
        File('${artwork.path}/${entry!.artworkFileName}'),
    ];
    // A previous crash may have left a file whose extension no longer
    // matches the record; sweep key-prefixed leftovers too.
    try {
      await for (final entity in tracks.list()) {
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (entity is File && name.startsWith('$key.')) targets.add(entity);
      }
    } catch (_) {
      // Listing failures must not block the known-target deletes below.
    }
    for (final target in targets) {
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {
        // Best-effort per file.
      }
    }
  }

  /// Total cached audio bytes across all valid records.
  Future<int> sizeBytes() async {
    final entries = await _readAllEntries();
    var total = 0;
    for (final entry in entries) {
      total += max(0, entry.bytes);
    }
    return total;
  }

  /// Background maintenance: prunes abandoned tmp writes, drops records
  /// whose audio is gone, deletes orphaned audio, enforces the budget.
  Future<PlaybackCacheMaintenanceReport> maintenance() async {
    await ensureLayout();
    var prunedTmp = 0;
    try {
      final tmp = await _sub(tmpDirName);
      final now = _clock();
      await for (final entity in tmp.list()) {
        if (entity is! File) continue;
        DateTime modified;
        try {
          modified = await entity.lastModified();
        } catch (_) {
          continue;
        }
        if (now.difference(modified) < tmpPruneAge) continue;
        try {
          await entity.delete();
          prunedTmp++;
        } catch (_) {
          // Best-effort per file.
        }
      }
    } catch (_) {
      // A missing/unreadable tmp dir is not a failure.
    }

    final entries = await _readAllEntries();
    final tracks = await _sub(tracksDirName);
    final liveNames = <String>{};
    for (final entry in entries) {
      final file = File('${tracks.path}/${entry.fileName}');
      bool exists = false;
      try {
        exists = await file.exists();
      } catch (_) {
        exists = false;
      }
      if (!exists) {
        await evictByKey(entry.key);
      } else {
        liveNames.add(entry.fileName);
      }
    }
    try {
      await for (final entity in tracks.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (name.isEmpty || liveNames.contains(name)) continue;
        try {
          await entity.delete();
        } catch (_) {
          // Best-effort per file.
        }
      }
    } catch (_) {
      // Best-effort sweep.
    }

    final sizeByKey = <String, int>{
      for (final entry in await _readAllEntries())
        entry.key: max(0, entry.bytes),
    };
    final evicted = await _enforceBudget();
    final remaining = await _readAllEntries();
    var total = 0;
    var freed = 0;
    for (final key in evicted) {
      freed += sizeByKey[key] ?? 0;
    }
    for (final entry in remaining) {
      total += max(0, entry.bytes);
    }
    return PlaybackCacheMaintenanceReport(
      evictedKeys: evicted,
      freedBytes: freed,
      totalBytes: total,
      entryCount: remaining.length,
      prunedTmpFiles: prunedTmp,
    );
  }

  /// Removes every cached artifact (keeps the directory layout).
  Future<void> clear() async {
    for (final name in const <String>[
      tracksDirName,
      artworkDirName,
      metadataDirName,
      tmpDirName,
    ]) {
      try {
        final dir = await _sub(name);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {
            // Best-effort per file.
          }
        }
      } catch (_) {
        // Best-effort per directory.
      }
    }
  }

  Future<PlaybackCacheEntry?> _readEntry(String key) async {
    try {
      final metadata = await _sub(metadataDirName);
      final file = File('${metadata.path}/$key.json');
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      return PlaybackCacheEntry.tryParse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeEntry(PlaybackCacheEntry entry) async {
    final metadata = await _sub(metadataDirName);
    final file = File('${metadata.path}/${entry.key}.json');
    await file.writeAsString(jsonEncode(entry.toJson()), flush: true);
  }

  Future<List<PlaybackCacheEntry>> _readAllEntries() async {
    final entries = <PlaybackCacheEntry>[];
    try {
      final metadata = await _sub(metadataDirName);
      if (!await metadata.exists()) return entries;
      await for (final entity in metadata.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = await entity.readAsString();
          final entry = PlaybackCacheEntry.tryParse(jsonDecode(raw));
          if (entry != null) entries.add(entry);
        } catch (_) {
          // Corrupt records are dropped by maintenance, not here.
        }
      }
    } catch (_) {
      // Missing/unreadable metadata dir reads as empty.
    }
    return entries;
  }

  Future<String?> _artworkPathOf(PlaybackCacheEntry entry) async {
    final name = entry.artworkFileName;
    if (name == null || name.isEmpty) return null;
    final dir = await _sub(artworkDirName);
    final file = File('${dir.path}/$name');
    try {
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _storeArtwork(String key, List<int> bytes) async {
    final dir = await _sub(artworkDirName);
    final fileName = '$key${_imageExtensionFor(bytes)}';
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) {
      await file.delete();
    }
    await file.writeAsBytes(bytes, flush: true);
    return fileName;
  }

  /// Evicts least-recently-used unpinned entries until under budget.
  /// Returns the evicted keys in eviction order.
  Future<List<String>> _enforceBudget() async {
    final budget = _maxSizeBytes;
    if (budget <= 0) return const <String>[];
    final entries = await _readAllEntries();
    var total = 0;
    for (final entry in entries) {
      total += max(0, entry.bytes);
    }
    if (total <= budget) return const <String>[];
    final evictable = entries.where((entry) => !entry.pinned).toList()
      ..sort((a, b) => a.lastAccessAt.compareTo(b.lastAccessAt));
    final evicted = <String>[];
    for (final entry in evictable) {
      if (total <= budget) break;
      await evictByKey(entry.key);
      total -= max(0, entry.bytes);
      evicted.add(entry.key);
    }
    return evicted;
  }

  static String _audioExtensionFor(String? format, List<int> bytes) {
    switch ((format ?? '').trim().toUpperCase()) {
      case 'FLAC':
        return '.flac';
      case 'MP3':
        return '.mp3';
      case 'M4A':
      case 'AAC':
      case 'MP4':
        return '.m4a';
      case 'OPUS':
        return '.opus';
      case 'OGG':
        return '.ogg';
      case 'WAV':
        return '.wav';
      case 'AIFF':
        return '.aiff';
    }
    if (bytes.length >= 4) {
      final magic = String.fromCharCodes(bytes.sublist(0, 4));
      if (magic == 'fLaC') return '.flac';
      if (magic == 'OggS') return '.ogg';
      if (magic == 'ID3') return '.mp3';
      if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return '.mp3';
      if (bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
        return '.m4a';
      }
      if (magic == 'RIFF') return '.wav';
    }
    return '.bin';
  }

  static String _imageExtensionFor(List<int> bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return '.jpg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return '.webp';
    }
    return '.bin';
  }
}

/// Plays verified cache hits on the shared player.
///
/// Cache hits render as local files (the handler's file path); only the
/// source chip differs (`Stream cache`), matching the hybrid manager's
/// cache presentation.
class CachePlaybackSource extends SharedBackendPlaybackSource {
  CachePlaybackSource({required super.backend, required PlaybackCacheManager cache})
    : _cache = cache;

  final PlaybackCacheManager _cache;

  PlaybackCacheManager get cache => _cache;

  /// Queue media id for a cache item: the cache key.
  static String mediaIdForCacheKey(String key) => key;

  @override
  PlaybackSourceKind get kind => PlaybackSourceKind.streamCache;

  @override
  Future<void> initialize() async {
    await backend.ensureReady();
    await _cache.ensureLayout();
  }

  @override
  Future<void> play(Track track) async {
    final hit = await _cache.lookup(track);
    if (hit == null) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'No cached copy of "${track.name}"',
      );
    }
    await _cache.registerPlay(track);
    await backend.playMedia(_mediaFor(track, hit));
  }

  @override
  Future<void> preload(Track track) async {
    final hit = await _cache.lookup(track);
    if (hit == null) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'No cached copy of "${track.name}"',
      );
    }
  }

  PlayableMedia mediaFor(Track track, PlaybackCacheHit hit) {
    return _mediaFor(track, hit);
  }

  PlayableMedia _mediaFor(Track track, PlaybackCacheHit hit) {
    final format = hit.entry.format.trim();
    return playableMediaForTrack(
      track,
      mediaId: mediaIdForCacheKey(hit.entry.key),
      source: hit.filePath,
      playbackMode: 'local',
      qualityLabel: format.isNotEmpty ? format : null,
      sourceLabel: 'Stream cache',
    );
  }
}
