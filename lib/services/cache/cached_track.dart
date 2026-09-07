/// Stream-cache row (Phase 1) — SQLite metadata for persistent stream bytes.
///
/// Complements the ecosystem byte cache (`ec_stream_cache`) with the
/// production playback ledger the audio engine consults *before* any network
/// work:
///
///   trackId · providerId · localPath · checksum · lastPlayed · size · expiry
///
/// Pure data: no Flutter, no I/O. Persistence lives in
/// [CachedTrackRepository].
library;

/// One cached stream artifact, keyed by logical track + provider.
class CachedTrackRecord {
  const CachedTrackRecord({
    required this.trackId,
    required this.providerId,
    required this.localPath,
    required this.checksum,
    required this.lastPlayed,
    required this.size,
    this.expiry,
    this.complete = true,
    this.bytesWritten = 0,
    this.sourceUrl = '',
    this.createdAt,
  });

  /// Canonical track identity (ISRC-first, else engine track id).
  final String trackId;

  /// Streaming provider that produced the bytes (`tidal`, `qobuz`, …).
  final String providerId;

  /// Absolute path of the staged/committed file.
  final String localPath;

  /// Hex SHA-256 of the *complete* plaintext bytes. Empty while partial.
  final String checksum;

  /// Last time the audio engine selected this copy for playback.
  final DateTime lastPlayed;

  /// Declared / measured size in bytes (0 while unknown).
  final int size;

  /// Optional hard expiry. Null → only LRU + TTL policy apply.
  final DateTime? expiry;

  /// False while a fetch is still running (resume candidate).
  final bool complete;

  /// Bytes already on disk for a partial fetch (resume offset).
  final int bytesWritten;

  /// Original stream URL, kept so a partial can be resumed.
  final String sourceUrl;

  final DateTime? createdAt;

  bool get isPlayable =>
      complete && localPath.isNotEmpty && checksum.isNotEmpty;

  bool get isPartial => !complete && bytesWritten > 0 && sourceUrl.isNotEmpty;

  bool isExpired(DateTime now) {
    final until = expiry;
    if (until == null) return false;
    return !until.isAfter(now);
  }

  CachedTrackRecord copyWith({
    String? localPath,
    String? checksum,
    DateTime? lastPlayed,
    int? size,
    DateTime? expiry,
    bool clearExpiry = false,
    bool? complete,
    int? bytesWritten,
    String? sourceUrl,
  }) {
    return CachedTrackRecord(
      trackId: trackId,
      providerId: providerId,
      localPath: localPath ?? this.localPath,
      checksum: checksum ?? this.checksum,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      size: size ?? this.size,
      expiry: clearExpiry ? null : (expiry ?? this.expiry),
      complete: complete ?? this.complete,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      createdAt: createdAt,
    );
  }

  /// Composite primary key used by the SQLite store.
  String get cacheKey => '$trackId|$providerId';

  Map<String, Object?> toRow() => <String, Object?>{
        'track_id': trackId,
        'provider_id': providerId,
        'local_path': localPath,
        'checksum': checksum,
        'last_played': lastPlayed.toUtc().toIso8601String(),
        'size': size,
        'expiry': expiry?.toUtc().toIso8601String(),
        'complete': complete ? 1 : 0,
        'bytes_written': bytesWritten,
        'source_url': sourceUrl,
        'created_at': (createdAt ?? lastPlayed).toUtc().toIso8601String(),
      };

  static CachedTrackRecord? fromRow(Map<String, Object?> row) {
    final trackId = row['track_id']?.toString() ?? '';
    if (trackId.isEmpty) return null;
    final lastPlayed =
        DateTime.tryParse(row['last_played']?.toString() ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final expiryRaw = row['expiry']?.toString();
    return CachedTrackRecord(
      trackId: trackId,
      providerId: row['provider_id']?.toString() ?? '',
      localPath: row['local_path']?.toString() ?? '',
      checksum: row['checksum']?.toString() ?? '',
      lastPlayed: lastPlayed,
      size: (row['size'] as num?)?.toInt() ?? 0,
      expiry: expiryRaw == null || expiryRaw.isEmpty
          ? null
          : DateTime.tryParse(expiryRaw)?.toUtc(),
      complete: row['complete'] == 1 || row['complete'] == true,
      bytesWritten: (row['bytes_written'] as num?)?.toInt() ?? 0,
      sourceUrl: row['source_url']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(row['created_at']?.toString() ?? '')?.toUtc(),
    );
  }
}

/// Configurable stream-cache budget. Clamped to 1 GiB … 100 GiB.
class StreamCacheBudget {
  const StreamCacheBudget._(this.maxBytes);

  /// Inclusive bounds the settings UI advertises.
  static const int minBytes = 1024 * 1024 * 1024; // 1 GiB
  static const int maxSupportedBytes = 100 * 1024 * 1024 * 1024; // 100 GiB
  static const int defaultBytes = 8 * 1024 * 1024 * 1024; // 8 GiB

  final int maxBytes;

  factory StreamCacheBudget.bytes(int bytes) {
    final clamped = bytes < minBytes
        ? minBytes
        : bytes > maxSupportedBytes
            ? maxSupportedBytes
            : bytes;
    return StreamCacheBudget._(clamped);
  }

  factory StreamCacheBudget.gigabytes(int gigabytes) =>
      StreamCacheBudget.bytes(gigabytes * 1024 * 1024 * 1024);

  int get gigabytes => maxBytes ~/ (1024 * 1024 * 1024);

  @override
  String toString() => 'StreamCacheBudget(${gigabytes}GiB)';
}

/// SQL schema for `stream_cache_tracks` (applied by the SQLite repository).
const String streamCacheTracksDdl = '''
CREATE TABLE IF NOT EXISTS stream_cache_tracks (
  track_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  local_path TEXT NOT NULL,
  checksum TEXT NOT NULL,
  last_played TEXT NOT NULL,
  size INTEGER NOT NULL,
  expiry TEXT,
  complete INTEGER NOT NULL,
  bytes_written INTEGER NOT NULL,
  source_url TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (track_id, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_stream_cache_last_played
  ON stream_cache_tracks(last_played);
CREATE INDEX IF NOT EXISTS idx_stream_cache_complete
  ON stream_cache_tracks(complete);
''';
