/// Continue Listening (Phase 8).
///
/// Two kinds of resume point, both stored in `ds_continue_listening`:
///
///   * `primary` — the single "pick up where you left off" row the home screen
///     shows at the top;
///   * one row per recent context (album, playlist, radio) so the user can
///     jump back into a *collection*, not just a track.
///
/// The row carries enough to resume without a lookup: track identity, cover,
/// local path, provider id and the surrounding queue. Playback therefore needs
/// zero extra I/O — which is what makes the resume feel seamless rather than
/// like a reload.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

/// What the resume point was started from.
enum ContinueContextKind { track, album, playlist, radio, queue }

/// The row id for the single top-of-home resume point.
const String primaryContinueSlot = 'primary';

/// How many queue neighbours are persisted around the resume position. Bounded
/// so a 5 000-track queue cannot balloon one row.
const int continueQueueWindow = 40;

/// One resumable point.
class ContinueListeningEntry {
  const ContinueListeningEntry({
    required this.slot,
    required this.kind,
    required this.track,
    this.positionMs = 0,
    this.durationMs = 0,
    this.contextId = '',
    this.contextLabel = '',
    this.queue = const <DiscoveryTrack>[],
    this.queueIndex = 0,
    required this.updatedAt,
  });

  final String slot;
  final ContinueContextKind kind;
  final DiscoveryTrack track;

  /// Resume offset. Zero means "start over" (a track finished, or the user
  /// never got far enough for a resume to be worth it).
  final int positionMs;
  final int durationMs;

  /// Id of the containing album/playlist/radio session, empty for a bare track.
  final String contextId;

  /// Display name of [contextId] ("Album · Night Visions").
  final String contextLabel;

  final List<DiscoveryTrack> queue;
  final int queueIndex;
  final DateTime updatedAt;

  /// 0..1 progress, or 0 when the duration is unknown.
  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  bool get hasResumePoint => positionMs > 1000;

  bool get hasQueue => queue.length > 1;

  /// Human-readable "12:04 left" style remaining time.
  String get remainingLabel {
    final remaining = durationMs - positionMs;
    if (remaining <= 0 || durationMs <= 0) return '';
    final totalSeconds = remaining ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')} left';
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'slot': slot,
    'kind': kind.name,
    'track_key': track.key,
    'title': track.title,
    'artist': track.artist,
    'album': track.album,
    'cover_url': track.coverUrl,
    'local_path': track.localPath,
    'provider_id': track.providerId,
    'external_id': track.externalId,
    'isrc': track.isrc,
    'position_ms': positionMs,
    'duration_ms': durationMs > 0
        ? durationMs
        : track.durationMs,
    'context_id': contextId,
    'context_label': contextLabel,
    'queue_json': encodeTracks(
      queue.length > continueQueueWindow
          ? _windowAround(queue, queueIndex, continueQueueWindow)
          : queue,
    ),
    'queue_index': queueIndex.clamp(0, queue.isEmpty ? 0 : queue.length - 1),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static ContinueListeningEntry? fromRow(Map<String, Object?> row) {
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    final title = row['title']?.toString() ?? '';
    final artist = row['artist']?.toString() ?? '';
    if (title.isEmpty && artist.isEmpty) return null;

    ContinueContextKind kind = ContinueContextKind.track;
    for (final value in ContinueContextKind.values) {
      if (value.name == row['kind']?.toString()) {
        kind = value;
        break;
      }
    }

    final track = DiscoveryTrack(
      key: row['track_key']?.toString() ?? '',
      title: title,
      artist: artist,
      artistKey: discoveryEntityKey(artist),
      album: row['album']?.toString() ?? '',
      albumKey: (row['album']?.toString() ?? '').isEmpty
          ? ''
          : discoveryEntityKey('${row['album']}|$artist'),
      coverUrl: row['cover_url']?.toString(),
      localPath: row['local_path']?.toString(),
      providerId: row['provider_id']?.toString(),
      externalId: row['external_id']?.toString(),
      isrc: row['isrc']?.toString(),
      durationMs: asInt('duration_ms'),
      isFavorite: false,
      source: (row['local_path']?.toString() ?? '').isEmpty
          ? DiscoverySource.listeningHistory
          : DiscoverySource.localLibrary,
    );

    final queueRaw = row['queue_json']?.toString();
    final queue = queueRaw == null || queueRaw.isEmpty
        ? const <DiscoveryTrack>[]
        : decodeTracks(_decodeList(queueRaw));

    return ContinueListeningEntry(
      slot: row['slot']?.toString() ?? primaryContinueSlot,
      kind: kind,
      track: track,
      positionMs: asInt('position_ms'),
      durationMs: asInt('duration_ms'),
      contextId: row['context_id']?.toString() ?? '',
      contextLabel: row['context_label']?.toString() ?? '',
      queue: queue,
      queueIndex: asInt('queue_index'),
      updatedAt:
          DateTime.tryParse(row['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  static List<DiscoveryTrack> _windowAround(
    List<DiscoveryTrack> queue,
    int index,
    int window,
  ) {
    final start = (index - window ~/ 2).clamp(0, queue.length);
    final end = (start + window).clamp(0, queue.length);
    return queue.sublist(start, end);
  }

  static Object? _decodeList(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}

/// Reads and writes resume points.
class ContinueListeningRepository {
  ContinueListeningRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// The single resume point shown at the top of the home screen.
  Future<ContinueListeningEntry?> primary() async {
    return read(primaryContinueSlot);
  }

  Future<ContinueListeningEntry?> read(String slot) async {
    final db = await _database.database;
    final rows = await db.query(
      dsContinueListening,
      where: 'slot = ?',
      whereArgs: <Object?>[slot],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ContinueListeningEntry.fromRow(rows.first);
  }

  /// Recent contexts, newest first. The primary slot is excluded so a screen
  /// can render "Continue" plus a list of contexts without duplicates.
  Future<List<ContinueListeningEntry>> recentContexts({int limit = 8}) async {
    final db = await _database.database;
    final rows = await db.query(
      dsContinueListening,
      where: 'slot <> ?',
      whereArgs: <Object?>[primaryContinueSlot],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    final entries = <ContinueListeningEntry>[];
    for (final row in rows) {
      final entry = ContinueListeningEntry.fromRow(row);
      if (entry != null) entries.add(entry);
    }
    return List<ContinueListeningEntry>.unmodifiable(entries);
  }

  /// Persists the primary resume point.
  ///
  /// A finished track (progress ≥ 95 %) clears the offset so the next resume
  /// starts from the top instead of skipping the intro — the same 90–95 %
  /// completion convention the listening history uses.
  Future<void> savePrimary(ContinueListeningEntry entry) async {
    final db = await _database.database;
    final durationMs = entry.durationMs > 0
        ? entry.durationMs
        : entry.track.durationMs;
    final finished =
        durationMs > 0 && entry.positionMs / durationMs >= 0.95;
    final normalised = ContinueListeningEntry(
      slot: primaryContinueSlot,
      kind: entry.kind,
      track: entry.track,
      positionMs: finished ? 0 : entry.positionMs,
      durationMs: durationMs,
      contextId: entry.contextId,
      contextLabel: entry.contextLabel,
      queue: entry.queue,
      queueIndex: entry.queueIndex,
      updatedAt: DateTime.now(),
    );
    await db.insert(
      dsContinueListening,
      normalised.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Persists a named context (album, playlist, radio session).
  Future<void> saveContext(ContinueListeningEntry entry) async {
    if (entry.slot == primaryContinueSlot) return savePrimary(entry);
    final db = await _database.database;
    await db.insert(
      dsContinueListening,
      ContinueListeningEntry(
        slot: entry.slot,
        kind: entry.kind,
        track: entry.track,
        positionMs: entry.positionMs,
        durationMs: entry.durationMs,
        contextId: entry.contextId,
        contextLabel: entry.contextLabel,
        queue: entry.queue,
        queueIndex: entry.queueIndex,
        updatedAt: DateTime.now(),
      ).toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> remove(String slot) async {
    final db = await _database.database;
    await db.delete(
      dsContinueListening,
      where: 'slot = ?',
      whereArgs: <Object?>[slot],
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsContinueListening);
  }
}
