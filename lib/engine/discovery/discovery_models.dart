/// Value types shared by the whole discovery / recommendation suite.
///
/// Pure Dart (no Flutter, no I/O) — the same rule as the rest of `lib/engine/`
/// (`recommendations.dart`, `replay_gain.dart`): the ranking maths must be
/// unit-testable headlessly and must never learn about SQLite or widgets.
///
/// Layering:
///   * this file + its siblings in `lib/engine/discovery/` hold *pure* logic;
///   * `lib/ecosystem/discovery/**` owns persistence and orchestration;
///   * `lib/providers/discovery_providers.dart` wires both into Riverpod.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

/// Lower-case, punctuation-stripped key used to group entities that differ
/// only in casing or in a stray "(feat. …)" suffix.
///
/// Deliberately cheap and dependency-free: it is called once per candidate,
/// not once per comparison, and every engine in this folder shares it so the
/// same two artists always collapse onto the same key.
String discoveryKey(String value) {
  final lower = value.trim().toLowerCase();
  if (lower.isEmpty) return '';
  final buffer = StringBuffer();
  var lastWasSpace = false;
  for (final unit in lower.codeUnits) {
    final isAlphanumeric =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x61 && unit <= 0x7a) ||
        unit > 0x7f; // keep non-Latin scripts (CJK, Cyrillic, Arabic…)
    if (isAlphanumeric) {
      buffer.writeCharCode(unit);
      lastWasSpace = false;
    } else if (!lastWasSpace) {
      buffer.writeCharCode(0x20);
      lastWasSpace = true;
    }
  }
  return buffer.toString().trim();
}

/// Canonical track identity: ISRC when present (it is the app-wide canonical
/// identity, see `engine/track_identity.dart`), else `title|artist`.
String discoveryTrackKey({
  required String title,
  required String artist,
  String? isrc,
}) {
  final code = isrc?.trim() ?? '';
  if (code.isNotEmpty) return 'isrc:${code.toUpperCase()}';
  return 'ta:${discoveryKey(title)}|${discoveryKey(artist)}';
}

/// Canonical entity key for artists/albums (label only — those entities have
/// no ISRC equivalent in the on-device data).
String discoveryEntityKey(String label) {
  final key = discoveryKey(label);
  return key.isEmpty ? '' : 'e:$key';
}

/// Splits a raw genre/tag string (`"Rock; Alternative, Indie"`) into clean
/// tokens. Providers emit wildly different separators; this is the one place
/// that normalises them so similarity maths compares like with like.
List<String> splitTaxonomy(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return const <String>[];
  final parts = value.split(RegExp(r'[;,/|]+'));
  final tokens = <String>[];
  final seen = <String>{};
  for (final part in parts) {
    final token = discoveryKey(part);
    if (token.isEmpty || token.length < 2) continue;
    if (!seen.add(token)) continue;
    tokens.add(token);
  }
  return List<String>.unmodifiable(tokens);
}

// ---------------------------------------------------------------------------
// Candidate
// ---------------------------------------------------------------------------

/// Kinds of entity a shelf can point at.
enum DiscoveryKind { track, artist, album, playlist }

/// Where a [DiscoveryTrack] came from. Drives offline gating: `localLibrary`
/// items always play without a network, everything else needs a provider.
enum DiscoverySource { localLibrary, listeningHistory, favorites, remote }

/// One rankable track.
///
/// Immutable value type with a JSON round trip, because every generated shelf
/// is cached in `ds_recommendation_cache` / `ds_daily_mixes` and rehydrated on
/// the next cold start (Phase 12: "home page load < 500 ms").
class DiscoveryTrack {
  const DiscoveryTrack({
    required this.key,
    required this.title,
    required this.artist,
    this.artistKey = '',
    this.album = '',
    this.albumKey = '',
    this.genres = const <String>[],
    this.tags = const <String>[],
    this.coverUrl,
    this.localPath,
    this.providerId,
    this.externalId,
    this.isrc,
    this.durationMs = 0,
    this.bpm,
    this.releaseDate,
    this.isFavorite = false,
    this.source = DiscoverySource.listeningHistory,
  });

  final String key;
  final String title;
  final String artist;
  final String artistKey;
  final String album;
  final String albumKey;

  /// Normalised genre tokens (see [splitTaxonomy]).
  final List<String> genres;

  /// Free-form descriptor tokens (mood, instrumentation, era) when a provider
  /// or the local tag reader supplied them.
  final List<String> tags;

  final String? coverUrl;

  /// Absolute path when the file is on this device, else null.
  final String? localPath;

  /// Extension/provider id that can resolve a stream for this track.
  final String? providerId;

  final String? externalId;
  final String? isrc;
  final int durationMs;

  /// Beats per minute when known from metadata. Null means "unknown" — the
  /// [MoodEngine] falls back to genre/tag evidence and says so in the UI
  /// instead of inventing a number.
  final int? bpm;

  final DateTime? releaseDate;
  final bool isFavorite;
  final DiscoverySource source;

  bool get isOfflinePlayable => localPath != null && localPath!.isNotEmpty;

  double get durationSeconds => durationMs / 1000.0;

  /// Taxonomy used for similarity: genres first, then tags. Kept as one list
  /// so a cosine pass never has to touch two maps.
  List<String> get taxonomy => <String>[...genres, ...tags];

  DiscoveryTrack copyWith({
    bool? isFavorite,
    String? coverUrl,
    String? localPath,
    int? bpm,
    List<String>? genres,
    List<String>? tags,
    DiscoverySource? source,
  }) {
    return DiscoveryTrack(
      key: key,
      title: title,
      artist: artist,
      artistKey: artistKey,
      album: album,
      albumKey: albumKey,
      genres: genres ?? this.genres,
      tags: tags ?? this.tags,
      coverUrl: coverUrl ?? this.coverUrl,
      localPath: localPath ?? this.localPath,
      providerId: providerId,
      externalId: externalId,
      isrc: isrc,
      durationMs: durationMs,
      bpm: bpm ?? this.bpm,
      releaseDate: releaseDate,
      isFavorite: isFavorite ?? this.isFavorite,
      source: source ?? this.source,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'k': key,
    't': title,
    'a': artist,
    if (artistKey.isNotEmpty) 'ak': artistKey,
    if (album.isNotEmpty) 'al': album,
    if (albumKey.isNotEmpty) 'alk': albumKey,
    if (genres.isNotEmpty) 'g': genres,
    if (tags.isNotEmpty) 'tg': tags,
    if (coverUrl != null) 'c': coverUrl,
    if (localPath != null) 'p': localPath,
    if (providerId != null) 'pr': providerId,
    if (externalId != null) 'x': externalId,
    if (isrc != null) 'i': isrc,
    if (durationMs > 0) 'd': durationMs,
    if (bpm != null) 'b': bpm,
    if (releaseDate != null) 'r': releaseDate!.toUtc().toIso8601String(),
    if (isFavorite) 'f': 1,
    's': source.name,
  };

  static DiscoveryTrack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    final key = json['k']?.toString() ?? '';
    final title = json['t']?.toString() ?? '';
    if (key.isEmpty || title.isEmpty) return null;
    final artist = json['a']?.toString() ?? '';
    return DiscoveryTrack(
      key: key,
      title: title,
      artist: artist,
      artistKey: json['ak']?.toString() ?? discoveryEntityKey(artist),
      album: json['al']?.toString() ?? '',
      albumKey: json['alk']?.toString() ?? '',
      genres: _stringList(json['g']),
      tags: _stringList(json['tg']),
      coverUrl: json['c']?.toString(),
      localPath: json['p']?.toString(),
      providerId: json['pr']?.toString(),
      externalId: json['x']?.toString(),
      isrc: json['i']?.toString(),
      durationMs: json['d'] is num ? (json['d']! as num).toInt() : 0,
      bpm: json['b'] is num ? (json['b']! as num).toInt() : null,
      releaseDate: DateTime.tryParse(json['r']?.toString() ?? ''),
      isFavorite: json['f'] == 1 || json['f'] == true,
      source: _source(json['s']?.toString()),
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return List<String>.unmodifiable(
      raw.whereType<Object>().map((entry) => entry.toString()),
    );
  }

  static DiscoverySource _source(String? raw) {
    for (final value in DiscoverySource.values) {
      if (value.name == raw) return value;
    }
    return DiscoverySource.listeningHistory;
  }

  @override
  bool operator ==(Object other) => other is DiscoveryTrack && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'DiscoveryTrack("$title" — $artist)';
}

/// JSON list codec shared by every cached shelf.
List<DiscoveryTrack> decodeTracks(Object? raw) {
  if (raw is! List) return const <DiscoveryTrack>[];
  final tracks = <DiscoveryTrack>[];
  final seen = <String>{};
  for (final entry in raw) {
    final track = DiscoveryTrack.fromJson(entry);
    if (track == null) continue;
    if (!seen.add(track.key)) continue;
    tracks.add(track);
  }
  return List<DiscoveryTrack>.unmodifiable(tracks);
}

/// Encodes [tracks] to a compact JSON string for a cache column.
String encodeTracks(List<DiscoveryTrack> tracks) {
  return jsonEncode(
    tracks.map((track) => track.toJson()).toList(growable: false),
  );
}

/// Parses a JSON array column into a string list, tolerating null/empty.
List<String> decodeStringList(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const <String>[];
    return List<String>.unmodifiable(
      decoded.whereType<Object>().map((entry) => entry.toString()),
    );
  } on FormatException {
    return const <String>[];
  }
}

// ---------------------------------------------------------------------------
// Listening signals
// ---------------------------------------------------------------------------

/// Listening-derived signals for one track, rolled up from the raw event log.
class TrackSignals {
  const TrackSignals({
    required this.trackKey,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.playCount = 0,
    this.skipCount = 0,
    this.completedCount = 0,
    this.repeatCount = 0,
    this.listenedMs = 0,
    this.completionSum = 0,
    required this.firstPlayedAt,
    required this.lastPlayedAt,
    this.isFavorite = false,
    this.playsInLast7Days = 0,
    this.playsInLast30Days = 0,
    this.playsInPrior30Days = 0,
  });

  final String trackKey;
  final String title;
  final String artist;
  final String album;

  final int playCount;
  final int skipCount;

  /// Plays that reached ≥ 90 % of the track (the app-wide completion rule).
  final int completedCount;

  /// Plays that started within the repeat window of the previous play of the
  /// same track — the "put it on again right away" signal.
  final int repeatCount;

  final int listenedMs;

  /// Σ completion ratios across plays that reported a duration.
  final double completionSum;

  final DateTime firstPlayedAt;
  final DateTime lastPlayedAt;
  final bool isFavorite;

  /// Windowed counts used by the trending engine without re-scanning events.
  final int playsInLast7Days;
  final int playsInLast30Days;
  final int playsInPrior30Days;

  /// 0..1 mean completion. Falls back to a duration-free estimate when no play
  /// ever reported a duration (older events).
  double get averageCompletion {
    if (playCount <= 0) return 0;
    final mean = completionSum / playCount;
    if (mean > 0) return mean.clamp(0.0, 1.0);
    return (completedCount / playCount).clamp(0.0, 1.0);
  }

  /// Share of plays abandoned early.
  double get skipRate => playCount <= 0 ? 0 : (skipCount / playCount).clamp(0.0, 1.0);

  /// Share of plays heard through.
  double get completionRate =>
      playCount <= 0 ? 0 : (completedCount / playCount).clamp(0.0, 1.0);

  /// Share of plays that were immediate repeats.
  double get repeatRate =>
      playCount <= 0 ? 0 : (repeatCount / playCount).clamp(0.0, 1.0);

  Duration get listened => Duration(milliseconds: listenedMs);

  TrackSignals copyWith({
    int? playsInLast7Days,
    int? playsInLast30Days,
    int? playsInPrior30Days,
    bool? isFavorite,
  }) {
    return TrackSignals(
      trackKey: trackKey,
      title: title,
      artist: artist,
      album: album,
      playCount: playCount,
      skipCount: skipCount,
      completedCount: completedCount,
      repeatCount: repeatCount,
      listenedMs: listenedMs,
      completionSum: completionSum,
      firstPlayedAt: firstPlayedAt,
      lastPlayedAt: lastPlayedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      playsInLast7Days: playsInLast7Days ?? this.playsInLast7Days,
      playsInLast30Days: playsInLast30Days ?? this.playsInLast30Days,
      playsInPrior30Days: playsInPrior30Days ?? this.playsInPrior30Days,
    );
  }
}

/// Taste weight on one axis value (an artist, album, genre or tag).
class TasteEntry {
  const TasteEntry({
    required this.key,
    required this.label,
    required this.affinity,
    this.playCount = 0,
    this.listenedMs = 0,
    this.skipRate = 0,
    this.averageCompletion = 0,
    this.isFavorite = false,
    required this.lastPlayedAt,
  });

  final String key;
  final String label;

  /// Decayed, 0..1 normalised affinity — the number every engine ranks on.
  final double affinity;

  final int playCount;
  final int listenedMs;
  final double skipRate;
  final double averageCompletion;
  final bool isFavorite;
  final DateTime lastPlayedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'k': key,
    'l': label,
    'w': affinity,
    'p': playCount,
    'ms': listenedMs,
    'sk': skipRate,
    'c': averageCompletion,
    if (isFavorite) 'f': 1,
    'at': lastPlayedAt.toUtc().toIso8601String(),
  };

  static TasteEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    final key = json['k']?.toString() ?? '';
    if (key.isEmpty) return null;
    double readDouble(String name) =>
        json[name] is num ? (json[name]! as num).toDouble() : 0;
    return TasteEntry(
      key: key,
      label: json['l']?.toString() ?? key,
      affinity: readDouble('w').clamp(0.0, 1.0),
      playCount: json['p'] is num ? (json['p']! as num).toInt() : 0,
      listenedMs: json['ms'] is num ? (json['ms']! as num).toInt() : 0,
      skipRate: readDouble('sk').clamp(0.0, 1.0),
      averageCompletion: readDouble('c').clamp(0.0, 1.0),
      isFavorite: json['f'] == 1 || json['f'] == true,
      lastPlayedAt:
          DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// Buckets of the day used by the habits model.
enum DaytimeBucket { morning, afternoon, evening, night }

/// Which bucket a UTC-local hour belongs to.
DaytimeBucket daytimeBucketForHour(int hour) {
  if (hour >= 5 && hour < 12) return DaytimeBucket.morning;
  if (hour >= 12 && hour < 17) return DaytimeBucket.afternoon;
  if (hour >= 17 && hour < 22) return DaytimeBucket.evening;
  return DaytimeBucket.night;
}

/// When the user listens, not what they listen to.
class ListeningHabits {
  const ListeningHabits({
    this.totalPlays = 0,
    this.totalListenedMs = 0,
    this.activeDays = 0,
    this.sessionCount = 0,
    this.totalSessionMs = 0,
    this.hourHistogram = const <int, int>{},
    this.weekdayPlays = 0,
    this.weekendPlays = 0,
    this.skipRate = 0,
    this.averageCompletion = 0,
  });

  final int totalPlays;
  final int totalListenedMs;
  final int activeDays;

  /// Number of distinct listening sessions (gaps > 30 min start a new one).
  final int sessionCount;
  final int totalSessionMs;

  /// Plays per hour of day, 0..23.
  final Map<int, int> hourHistogram;

  final int weekdayPlays;
  final int weekendPlays;
  final double skipRate;
  final double averageCompletion;

  double get averageSessionMinutes =>
      sessionCount <= 0 ? 0 : (totalSessionMs / sessionCount) / 60000.0;

  double get averageDailyMinutes =>
      activeDays <= 0 ? 0 : (totalListenedMs / activeDays) / 60000.0;

  double get weekendShare {
    final total = weekdayPlays + weekendPlays;
    return total <= 0 ? 0 : weekendPlays / total;
  }

  /// Normalised distribution across [DaytimeBucket] (sums to 1 when there is
  /// any data, all zeros when there is none).
  Map<DaytimeBucket, double> get daytimeDistribution {
    final totals = <DaytimeBucket, int>{
      for (final bucket in DaytimeBucket.values) bucket: 0,
    };
    var total = 0;
    for (final entry in hourHistogram.entries) {
      if (entry.key < 0 || entry.key > 23) continue;
      final bucket = daytimeBucketForHour(entry.key);
      totals[bucket] = (totals[bucket] ?? 0) + entry.value;
      total += entry.value;
    }
    if (total <= 0) {
      return <DaytimeBucket, double>{
        for (final bucket in DaytimeBucket.values) bucket: 0,
      };
    }
    return <DaytimeBucket, double>{
      for (final entry in totals.entries) entry.key: entry.value / total,
    };
  }

  /// The bucket the user listens in most, or null with no data.
  DaytimeBucket? get dominantBucket {
    final distribution = daytimeDistribution;
    DaytimeBucket? best;
    var bestShare = 0.0;
    for (final entry in distribution.entries) {
      if (entry.value > bestShare) {
        bestShare = entry.value;
        best = entry.key;
      }
    }
    return best;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'plays': totalPlays,
    'ms': totalListenedMs,
    'days': activeDays,
    'sessions': sessionCount,
    'sessionMs': totalSessionMs,
    'hours': <String, Object?>{
      for (final entry in hourHistogram.entries) '${entry.key}': entry.value,
    },
    'wd': weekdayPlays,
    'we': weekendPlays,
    'skip': skipRate,
    'completion': averageCompletion,
  };

  static ListeningHabits fromJson(Object? raw) {
    if (raw is! Map) return const ListeningHabits();
    final json = Map<String, Object?>.from(raw);
    int readInt(String name) =>
        json[name] is num ? (json[name]! as num).toInt() : 0;
    double readDouble(String name) =>
        json[name] is num ? (json[name]! as num).toDouble() : 0;
    final rawHours = json['hours'];
    final histogram = <int, int>{};
    if (rawHours is Map) {
      for (final entry in rawHours.entries) {
        final hour = int.tryParse(entry.key.toString());
        if (hour == null || hour < 0 || hour > 23) continue;
        final value = entry.value;
        if (value is! num) continue;
        histogram[hour] = value.toInt();
      }
    }
    return ListeningHabits(
      totalPlays: readInt('plays'),
      totalListenedMs: readInt('ms'),
      activeDays: readInt('days'),
      sessionCount: readInt('sessions'),
      totalSessionMs: readInt('sessionMs'),
      hourHistogram: Map<int, int>.unmodifiable(histogram),
      weekdayPlays: readInt('wd'),
      weekendPlays: readInt('we'),
      skipRate: readDouble('skip'),
      averageCompletion: readDouble('completion'),
    );
  }
}

/// The complete on-device picture of one user's taste (Phase 1).
///
/// Built once per refresh by `UserProfileEngine`, cached in `ds_user_profiles`
/// and read synchronously by every engine downstream.
class ListeningProfile {
  const ListeningProfile({
    this.generatedAt,
    this.tracks = const <TasteEntry>[],
    this.artists = const <TasteEntry>[],
    this.albums = const <TasteEntry>[],
    this.genres = const <TasteEntry>[],
    this.tags = const <TasteEntry>[],
    this.habits = const ListeningHabits(),
  });

  static const ListeningProfile empty = ListeningProfile();

  final DateTime? generatedAt;

  /// Best first (affinity desc).
  final List<TasteEntry> tracks;
  final List<TasteEntry> artists;
  final List<TasteEntry> albums;
  final List<TasteEntry> genres;
  final List<TasteEntry> tags;
  final ListeningHabits habits;

  bool get isCold => tracks.isEmpty && artists.isEmpty;

  /// Affinity lookup used by the scorer; keys are [discoveryEntityKey]s.
  Map<String, double> get artistAffinity => <String, double>{
    for (final entry in artists) entry.key: entry.affinity,
  };

  Map<String, double> get genreAffinity => <String, double>{
    for (final entry in genres) entry.key: entry.affinity,
  };

  Map<String, double> get albumAffinity => <String, double>{
    for (final entry in albums) entry.key: entry.affinity,
  };

  Map<String, double> get tagAffinity => <String, double>{
    for (final entry in tags) entry.key: entry.affinity,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    if (generatedAt != null)
      'generatedAt': generatedAt!.toUtc().toIso8601String(),
    'tracks': tracks.map((entry) => entry.toJson()).toList(growable: false),
    'artists': artists.map((entry) => entry.toJson()).toList(growable: false),
    'albums': albums.map((entry) => entry.toJson()).toList(growable: false),
    'genres': genres.map((entry) => entry.toJson()).toList(growable: false),
    'tags': tags.map((entry) => entry.toJson()).toList(growable: false),
    'habits': habits.toJson(),
  };

  static ListeningProfile fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final json = Map<String, Object?>.from(raw);

    List<TasteEntry> readEntries(String name) {
      final value = json[name];
      if (value is! List) return const <TasteEntry>[];
      final entries = <TasteEntry>[];
      for (final entry in value) {
        final taste = TasteEntry.fromJson(entry);
        if (taste != null) entries.add(taste);
      }
      return List<TasteEntry>.unmodifiable(entries);
    }

    return ListeningProfile(
      generatedAt: DateTime.tryParse(json['generatedAt']?.toString() ?? ''),
      tracks: readEntries('tracks'),
      artists: readEntries('artists'),
      albums: readEntries('albums'),
      genres: readEntries('genres'),
      tags: readEntries('tags'),
      habits: ListeningHabits.fromJson(json['habits']),
    );
  }
}

// ---------------------------------------------------------------------------
// Scored output
// ---------------------------------------------------------------------------

/// Why a track was recommended — surfaced verbatim in the UI so a shelf
/// explains itself instead of looking arbitrary.
class RecommendationReason {
  const RecommendationReason(this.code, this.label);

  /// Stable machine code (`artist`, `genre`, `favorite`, `rediscovery`…).
  final String code;

  /// Human-readable, already-localised by the caller.
  final String label;

  Map<String, Object?> toJson() => <String, Object?>{'c': code, 'l': label};

  static RecommendationReason? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['c']?.toString() ?? '';
    if (code.isEmpty) return null;
    return RecommendationReason(code, raw['l']?.toString() ?? '');
  }
}

/// Per-component contribution to a [ScoredTrack]'s score.
class ScoreBreakdown {
  const ScoreBreakdown({
    this.recency = 0,
    this.frequency = 0,
    this.favorite = 0,
    this.similarity = 0,
    this.reasons = const <RecommendationReason>[],
  });

  /// 0..1 contribution *after* weighting, for each of the four axes.
  final double recency;
  final double frequency;
  final double favorite;
  final double similarity;
  final List<RecommendationReason> reasons;

  double get total => recency + frequency + favorite + similarity;

  ScoreBreakdown copyWith({List<RecommendationReason>? reasons}) {
    return ScoreBreakdown(
      recency: recency,
      frequency: frequency,
      favorite: favorite,
      similarity: similarity,
      reasons: reasons ?? this.reasons,
    );
  }
}

/// A ranked candidate.
class ScoredTrack {
  const ScoredTrack({
    required this.track,
    required this.score,
    this.breakdown = const ScoreBreakdown(),
    this.source = 'local',
  });

  final DiscoveryTrack track;

  /// 0..100 recommendation score (Phase 2 contract).
  final double score;

  final ScoreBreakdown breakdown;

  /// Id of the engine that produced this ranking.
  final String source;

  /// First human-readable reason, or null.
  String? get primaryReason =>
      breakdown.reasons.isEmpty ? null : breakdown.reasons.first.label;

  ScoredTrack copyWith({double? score, ScoreBreakdown? breakdown}) {
    return ScoredTrack(
      track: track,
      score: score ?? this.score,
      breakdown: breakdown ?? this.breakdown,
      source: source,
    );
  }
}

/// A generated shelf: a named, ordered, cacheable list of tracks.
class GeneratedShelf {
  const GeneratedShelf({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.items = const <ScoredTrack>[],
    this.generatedAt,
    this.expiresAt,
    this.seedLabels = const <String>[],
    this.accentSeed,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<ScoredTrack> items;
  final DateTime? generatedAt;
  final DateTime? expiresAt;

  /// Names of the seeds that drove generation (shown as chips).
  final List<String> seedLabels;

  /// Optional cover fallback when no track artwork is available.
  final String? accentSeed;

  int get trackCount => items.length;

  bool get isEmpty => items.isEmpty;

  List<DiscoveryTrack> get tracks =>
      items.map((entry) => entry.track).toList(growable: false);

  bool get isExpired {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return DateTime.now().isAfter(expiry);
  }

  GeneratedShelf copyWith({
    DateTime? generatedAt,
    DateTime? expiresAt,
    List<ScoredTrack>? items,
    String? subtitle,
  }) {
    return GeneratedShelf(
      id: id,
      title: title,
      subtitle: subtitle ?? this.subtitle,
      items: items ?? this.items,
      generatedAt: generatedAt ?? this.generatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      seedLabels: seedLabels,
      accentSeed: accentSeed,
    );
  }
}
