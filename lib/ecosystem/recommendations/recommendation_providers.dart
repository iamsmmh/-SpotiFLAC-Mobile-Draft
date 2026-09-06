/// Recommendation providers: cloud, similarity and daily-mix sources
/// (Feature Group 5).
///
/// Everything implements the app's existing [RecommendationProvider] port from
/// `engine/recommendations.dart`, so [RecommendationService] chains them with
/// no changes: the first provider that fills a shelf kind wins, and the local
/// engine remains the always-available fallback.
///
/// Provider order built by [RecommendationRegistry]:
///   1. cloud (when configured)   — server-side/AI recommendations
///   2. similarity (on-device)    — content-based similar tracks/artists/albums
///   3. daily mix (on-device)     — rotating discovery mixes
///   4. local engine              — recently/frequently played, discovery mix
library;

import 'dart:convert';
import 'dart:math' show sqrt;

import 'package:http/http.dart' as http;
import 'package:spotimusic/engine/recommendations.dart';
import 'package:spotimusic/utils/logger.dart';

final _log = AppLogger('Recommendations');

// ---------------------------------------------------------------------------
// Wire codec (shared by the cloud provider, tests and docs)
// ---------------------------------------------------------------------------

/// JSON <-> [RecommendationSection] translation for the cloud contract
/// documented in `docs/API_CONTRACTS.md`.
class RecommendationCodec {
  const RecommendationCodec();

  Map<String, Object?> encodeProfile(RecommendationProfile profile) =>
      <String, Object?>{
        'dailySeed': profile.dailySeed,
        'plays': profile.plays
            .map(
              (play) => <String, Object?>{
                'trackId': play.trackId,
                'title': play.title,
                'artist': play.artist,
                'album': play.album,
                'playCount': play.playCount,
                'listenedMs': play.listenedMs,
                if (play.lastPlayedAt != null)
                  'lastPlayedAt': play.lastPlayedAt!.toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
        'favoriteArtists': profile.favoriteArtists
            .map(
              (artist) => <String, Object?>{
                'id': artist.id,
                'name': artist.name,
                'kind': artist.kind.name,
                if (artist.imageUrl != null) 'imageUrl': artist.imageUrl,
                if (artist.providerId != null) 'providerId': artist.providerId,
              },
            )
            .toList(growable: false),
        'lovedTracks': profile.lovedTracks
            .map(
              (track) => <String, Object?>{
                'trackId': track.trackId,
                'title': track.title,
                'artist': track.artist,
                'album': track.album,
              },
            )
            .toList(growable: false),
      };

  List<RecommendationSection> decodeSections(Object? raw) {
    if (raw is! List) return const <RecommendationSection>[];
    final sections = <RecommendationSection>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final section = decodeSection(Map<String, Object?>.from(entry));
      if (section != null && !section.isEmpty) sections.add(section);
    }
    return sections;
  }

  RecommendationSection? decodeSection(Map<String, Object?> json) {
    final kind = _kind(json['kind']?.toString());
    final rawItems = json['items'];
    if (kind == null || rawItems is! List) return null;
    final items = <RecommendedItem>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final item = decodeItem(Map<String, Object?>.from(entry));
      if (item != null) items.add(item);
    }
    if (items.isEmpty) return null;
    return RecommendationSection(
      kind: kind,
      title: json['title']?.toString() ?? '',
      items: List<RecommendedItem>.unmodifiable(items),
    );
  }

  RecommendedItem? decodeItem(Map<String, Object?> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return RecommendedItem(
      kind: _itemKind(json['itemKind']?.toString()),
      id: id,
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString(),
      providerId: json['providerId']?.toString(),
      score: json['score'] is num
          ? (json['score']! as num).toDouble()
          : 0,
    );
  }

  static RecommendationSectionKind? _kind(String? value) {
    for (final kind in RecommendationSectionKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  static RecommendedItemKind _itemKind(String? value) {
    for (final kind in RecommendedItemKind.values) {
      if (kind.name == value) return kind;
    }
    return RecommendedItemKind.track;
  }
}

// ---------------------------------------------------------------------------
// Cloud provider
// ---------------------------------------------------------------------------

/// Endpoint + credential layout for [CloudRecommendationProvider].
class CloudRecommendationConfig {
  const CloudRecommendationConfig({
    required this.baseUrl,
    this.path = '/v1/recommendations',
    this.apiKey = '',
    this.timeoutSeconds = 8,
  });

  final String baseUrl;
  final String path;
  final String apiKey;
  final int timeoutSeconds;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'path': path,
    'apiKey': apiKey,
    'timeoutSeconds': timeoutSeconds,
  };

  static CloudRecommendationConfig fromJson(Map<String, Object?> json) {
    return CloudRecommendationConfig(
      baseUrl: json['baseUrl']?.toString() ?? '',
      path: json['path']?.toString() ?? '/v1/recommendations',
      apiKey: json['apiKey']?.toString() ?? '',
      timeoutSeconds: json['timeoutSeconds'] is num
          ? (json['timeoutSeconds']! as num).toInt()
          : 8,
    );
  }
}

/// Remote recommendation source (self-hosted recommender, collaborative
/// filtering service, or an AI model behind the same contract).
///
/// Fails open: any transport or parse problem yields an empty list, which the
/// aggregating service treats as "this provider has nothing right now" and
/// falls through to the on-device engines.
class CloudRecommendationProvider implements RecommendationProvider {
  CloudRecommendationProvider({
    required this.config,
    http.Client? client,
    RecommendationCodec? codec,
    Future<String?> Function()? tokenProvider,
  }) : _client = client ?? http.Client(),
       _codec = codec ?? const RecommendationCodec(),
       _tokenProvider = tokenProvider;

  CloudRecommendationConfig config;
  final http.Client _client;
  final RecommendationCodec _codec;
  final Future<String?> Function()? _tokenProvider;

  static const String providerId = 'cloud';

  @override
  String get id => providerId;

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async {
    if (!config.isConfigured) return const <RecommendationSection>[];
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base${config.path}');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (config.apiKey.isNotEmpty) 'X-Api-Key': config.apiKey,
    };
    final token = await _tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    try {
      final response = await _client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, Object?>{
              ..._codec.encodeProfile(profile),
              'maxItemsPerSection': maxItemsPerSection,
            }),
          )
          .timeout(Duration(seconds: config.timeoutSeconds));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.i('Cloud recommendations: HTTP ${response.statusCode}');
        return const <RecommendationSection>[];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return const <RecommendationSection>[];
      final map = Map<String, Object?>.from(decoded);
      final sections = _codec.decodeSections(map['sections']);
      return sections
          .map(
            (section) => RecommendationSection(
              kind: section.kind,
              title: section.title,
              items: section.items.take(maxItemsPerSection).toList(
                growable: false,
              ),
            ),
          )
          .toList(growable: false);
    } catch (error) {
      _log.i('Cloud recommendations unavailable: $error');
      return const <RecommendationSection>[];
    }
  }

  void dispose() {
    _client.close();
  }
}

// ---------------------------------------------------------------------------
// On-device similarity
// ---------------------------------------------------------------------------

/// A catalog row the similarity index can reason about.
class SimilarityTrack {
  const SimilarityTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.genre = '',
    this.durationSeconds = 0,
    this.releaseYear,
    this.imageUrl,
    this.providerId,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int durationSeconds;
  final int? releaseYear;
  final String? imageUrl;
  final String? providerId;
}

/// Content-based similarity over a local catalog.
///
/// Honest about its model: every track is a TF-weighted bag of features
/// (artist, album, genre, decade, duration bucket, title tokens) and related
/// items are the nearest neighbours by cosine similarity. No external graph is
/// involved, so it works offline and needs no user history — but it can only
/// relate music it has metadata for.
class SimilarityIndex {
  SimilarityIndex(Iterable<SimilarityTrack> catalog) {
    for (final track in catalog) {
      if (track.id.isEmpty) continue;
      _tracks[track.id] = track;
      _vectors[track.id] = _vectorize(track);
    }
    for (final track in _tracks.values) {
      _byArtist.putIfAbsent(_key(track.artist), () => <String>[]).add(track.id);
      if (track.album.isNotEmpty) {
        _byAlbum
            .putIfAbsent(_key('${track.artist}|${track.album}'), () => <String>[])
            .add(track.id);
      }
    }
  }

  final Map<String, SimilarityTrack> _tracks = <String, SimilarityTrack>{};
  final Map<String, Map<String, double>> _vectors =
      <String, Map<String, double>>{};
  final Map<String, List<String>> _byArtist = <String, List<String>>{};
  final Map<String, List<String>> _byAlbum = <String, List<String>>{};

  int get size => _tracks.length;

  SimilarityTrack? track(String id) => _tracks[id];

  /// Nearest tracks to [seedId], excluding the seed itself.
  List<SimilarityEntry> similarTracks(String seedId, {int limit = 20}) {
    final seedVector = _vectors[seedId];
    if (seedVector == null) return const <SimilarityEntry>[];
    final scored = <SimilarityEntry>[];
    for (final entry in _vectors.entries) {
      if (entry.key == seedId) continue;
      final score = _cosine(seedVector, entry.value);
      if (score <= 0) continue;
      final track = _tracks[entry.key];
      if (track == null) continue;
      scored.add(SimilarityEntry(track: track, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  /// Artists closest to [artistName], ranked by centroid similarity.
  List<SimilarityEntry> similarArtists(String artistName, {int limit = 10}) {
    final centroid = _artistCentroid(artistName);
    if (centroid == null) return const <SimilarityEntry>[];
    final scored = <SimilarityEntry>[];
    for (final artistEntry in _byArtist.entries) {
      if (artistEntry.key == _key(artistName)) continue;
      final otherCentroid = _artistCentroidFromIds(artistEntry.value);
      if (otherCentroid == null) continue;
      final score = _cosine(centroid, otherCentroid);
      if (score <= 0) continue;
      final sample = _tracks[artistEntry.value.first];
      if (sample == null) continue;
      scored.add(
        SimilarityEntry(
          track: SimilarityTrack(
            id: 'artist:${artistEntry.key}',
            title: sample.artist,
            artist: sample.artist,
            imageUrl: sample.imageUrl,
            providerId: sample.providerId,
          ),
          score: score,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  /// Albums closest to a seed album (`artist|album` key).
  List<SimilarityEntry> similarAlbums(String artist, String album, {int limit = 10}) {
    final seedIds = _byAlbum[_key('$artist|$album')];
    if (seedIds == null) return const <SimilarityEntry>[];
    final centroid = _artistCentroidFromIds(seedIds);
    if (centroid == null) return const <SimilarityEntry>[];
    final scored = <SimilarityEntry>[];
    for (final albumEntry in _byAlbum.entries) {
      if (albumEntry.key == _key('$artist|$album')) continue;
      final other = _artistCentroidFromIds(albumEntry.value);
      if (other == null) continue;
      final score = _cosine(centroid, other);
      if (score <= 0) continue;
      final sample = _tracks[albumEntry.value.first];
      if (sample == null) continue;
      scored.add(
        SimilarityEntry(
          track: SimilarityTrack(
            id: 'album:${albumEntry.key}',
            title: sample.album,
            artist: sample.artist,
            imageUrl: sample.imageUrl,
            providerId: sample.providerId,
          ),
          score: score,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  Map<String, double>? _artistCentroid(String artist) =>
      _artistCentroidFromIds(_byArtist[_key(artist)] ?? const <String>[]);

  Map<String, double>? _artistCentroidFromIds(List<String> ids) {
    if (ids.isEmpty) return null;
    final centroid = <String, double>{};
    for (final id in ids) {
      final vector = _vectors[id];
      if (vector == null) continue;
      for (final entry in vector.entries) {
        centroid[entry.key] = (centroid[entry.key] ?? 0) + entry.value;
      }
    }
    if (centroid.isEmpty) return null;
    final count = ids.length.toDouble();
    return centroid.map((key, value) => MapEntry(key, value / count));
  }

  static Map<String, double> _vectorize(SimilarityTrack track) {
    final vector = <String, double>{};
    void bump(String feature, double weight) {
      vector[feature] = (vector[feature] ?? 0) + weight;
    }

    for (final token in _tokens(track.artist)) {
      bump('artist:$token', 3);
    }
    for (final token in _tokens(track.album)) {
      bump('album:$token', 2);
    }
    for (final token in _tokens(track.title)) {
      bump('title:$token', 1);
    }
    for (final token in _tokens(track.genre)) {
      bump('genre:$token', 2);
    }
    if (track.releaseYear != null) {
      bump('decade:${(track.releaseYear! ~/ 10) * 10}', 1);
    }
    if (track.durationSeconds > 0) {
      bump('length:${track.durationSeconds ~/ 60}', 0.5);
    }
    return vector;
  }

  static double _cosine(Map<String, double> a, Map<String, double> b) {
    double dot = 0;
    double normA = 0;
    double normB = 0;
    for (final entry in a.entries) {
      normA += entry.value * entry.value;
      final other = b[entry.key];
      if (other != null) dot += entry.value * other;
    }
    for (final value in b.values) {
      normB += value * value;
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  static String _key(String value) => value.trim().toLowerCase();

  static Iterable<String> _tokens(String value) sync* {
    final lowered = value.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lowered.runes) {
      final char = String.fromCharCode(rune);
      final code = char.codeUnitAt(0);
      final isWord = (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
      if (isWord) {
        buffer.write(char);
      } else if (buffer.isNotEmpty) {
        yield buffer.toString();
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) yield buffer.toString();
  }
}

/// A scored similarity result.
class SimilarityEntry {
  const SimilarityEntry({required this.track, required this.score});

  final SimilarityTrack track;
  final double score;
}

/// Wraps a [SimilarityIndex] behind the [RecommendationProvider] port so the
/// "similar tracks/artists" shelves are filled on-device.
class SimilarityRecommendationProvider implements RecommendationProvider {
  const SimilarityRecommendationProvider({
    required this.index,
    required this.seeds,
  });

  final SimilarityIndex index;

  /// Seed track ids (usually the user's most played tracks).
  final List<String> seeds;

  static const String providerId = 'similarity';

  @override
  String get id => providerId;

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async {
    if (index.size == 0) return const <RecommendationSection>[];

    final effectiveSeeds = seeds.isNotEmpty
        ? seeds
        : profile.plays
              .take(5)
              .map((play) => play.trackId)
              .toList(growable: false);
    if (effectiveSeeds.isEmpty) return const <RecommendationSection>[];

    final tracks = <RecommendedItem>[];
    final seenTracks = <String>{};
    for (final seed in effectiveSeeds.take(5)) {
      for (final entry in index.similarTracks(seed, limit: maxItemsPerSection)) {
        if (!seenTracks.add(entry.track.id)) continue;
        tracks.add(
          RecommendedItem(
            kind: RecommendedItemKind.track,
            id: entry.track.id,
            title: entry.track.title,
            subtitle: entry.track.artist,
            imageUrl: entry.track.imageUrl,
            providerId: entry.track.providerId,
            score: entry.score,
          ),
        );
      }
    }
    tracks.sort((a, b) => b.score.compareTo(a.score));

    final artists = <RecommendedItem>[];
    final seenArtists = <String>{};
    for (final seed in effectiveSeeds.take(3)) {
      final seedTrack = index.track(seed);
      if (seedTrack == null) continue;
      for (final entry in index.similarArtists(seedTrack.artist, limit: 8)) {
        if (!seenArtists.add(entry.track.title.toLowerCase())) continue;
        artists.add(
          RecommendedItem(
            kind: RecommendedItemKind.artist,
            id: entry.track.id,
            title: entry.track.title,
            imageUrl: entry.track.imageUrl,
            providerId: entry.track.providerId,
            score: entry.score,
          ),
        );
      }
    }
    artists.sort((a, b) => b.score.compareTo(a.score));

    return <RecommendationSection>[
      if (tracks.isNotEmpty)
        RecommendationSection(
          kind: RecommendationSectionKind.similarTracks,
          title: 'Similar tracks',
          items: tracks.take(maxItemsPerSection).toList(growable: false),
        ),
      if (artists.isNotEmpty)
        RecommendationSection(
          kind: RecommendationSectionKind.similarArtists,
          title: 'Similar artists',
          items: artists.take(maxItemsPerSection).toList(growable: false),
        ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Daily mix
// ---------------------------------------------------------------------------

/// Rotating discovery mixes: the shelf reshuffles once per UTC day per mix,
/// driven by [RecommendationProfile.dailySeed].
class DailyMixProvider implements RecommendationProvider {
  const DailyMixProvider({this.mixCount = 3});

  final int mixCount;

  static const String providerId = 'daily_mix';

  @override
  String get id => providerId;

  /// Deterministic per-(day, mix) rotation offset.
  static int rotationFor(int dailySeed, int mixIndex) =>
      dailySeed * 31 + mixIndex * 7;

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async {
    if (profile.isCold) return const <RecommendationSection>[];
    // The profile carries affinities in the order the collections store
    // returns them (currently insertion order), so rank == position and no
    // weight field is needed.
    final artists = profile.favoriteArtists;
    if (artists.isEmpty) return const <RecommendationSection>[];

    final items = <RecommendedItem>[];
    for (var mix = 0; mix < mixCount; mix++) {
      final offset = rotationFor(profile.dailySeed ?? 0, mix);
      for (var slot = 0; slot < maxItemsPerSection; slot++) {
        final index = (offset + slot * 3) % artists.length;
        final artist = artists[index];
        items.add(
          RecommendedItem(
            kind: artist.kind,
            id: 'mix${mix + 1}:${artist.id}',
            title: artist.name,
            subtitle: 'Daily Mix ${mix + 1}',
            imageUrl: artist.imageUrl,
            providerId: artist.providerId,
            score: (artists.length - slot) / artists.length.toDouble(),
          ),
        );
      }
    }
    return <RecommendationSection>[
      RecommendationSection(
        kind: RecommendationSectionKind.discoveryMix,
        title: 'Daily Mix',
        items: items,
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// Builds the provider chain used by the app.
class RecommendationRegistry {
  RecommendationRegistry({
    CloudRecommendationProvider? cloud,
    SimilarityRecommendationProvider? similarity,
    bool includeDailyMix = true,
    bool includeLocalEngine = true,
  }) : _cloud = cloud,
       _similarity = similarity,
       _includeDailyMix = includeDailyMix,
       _includeLocalEngine = includeLocalEngine;

  final CloudRecommendationProvider? _cloud;
  final SimilarityRecommendationProvider? _similarity;
  final bool _includeDailyMix;
  final bool _includeLocalEngine;

  /// Assembles the chain, richest source first and the local engine last.
  RecommendationService build() {
    final providers = <RecommendationProvider>[
      if (_cloud != null && _cloud.config.isConfigured) _cloud,
      if (_similarity != null) _similarity,
      if (_includeDailyMix) const DailyMixProvider(),
    ];
    final service = RecommendationService(providers: providers);
    return _includeLocalEngine
        ? service.withProvider(const LocalRecommendationEngine())
        : service;
  }

  /// Ids in the order they will be consulted.
  List<String> get providerOrder => <String>[
    if (_cloud != null && _cloud.config.isConfigured)
      CloudRecommendationProvider.providerId,
    if (_similarity != null) SimilarityRecommendationProvider.providerId,
    if (_includeDailyMix) DailyMixProvider.providerId,
    if (_includeLocalEngine) LocalRecommendationEngine.providerId,
  ];
}
