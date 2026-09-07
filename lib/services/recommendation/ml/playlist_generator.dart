/// Playlist generator (Phase 6) — Discover Weekly, Daily Mixes, mood /
/// artist mixes, Release Radar.
///
/// Deterministic given a seed + taste model so two devices with the same
/// signals produce the same mix for the same UTC day.
library;

import 'package:spotiflac_android/services/recommendation/ml/ml_similarity_engine.dart';
import 'package:spotiflac_android/services/recommendation/ml/user_taste_model.dart';

/// Kinds of generated mix this generator can emit.
enum GeneratedMixKind {
  discoverWeekly,
  releaseRadar,
  dailyMix,
  moodMix,
  artistMix,
}

/// One generated playlist.
class GeneratedMix {
  const GeneratedMix({
    required this.kind,
    required this.id,
    required this.title,
    required this.trackIds,
  });

  final GeneratedMixKind kind;
  final String id;
  final String title;
  final List<String> trackIds;
}

/// Builds mixes from a taste model + candidate pool.
class PlaylistGenerator {
  const PlaylistGenerator({
    this.similarity = const MlSimilarityEngine(),
    this.mixSize = 30,
  });

  final MlSimilarityEngine similarity;
  final int mixSize;

  /// Deterministic daily seed (UTC day ordinal) so a mix is stable for 24 h.
  static int dailySeed(DateTime utc) {
    final day = DateTime.utc(utc.year, utc.month, utc.day);
    return day.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  }

  GeneratedMix discoverWeekly({
    required UserTasteModel taste,
    required List<TasteSignal> pool,
    required DateTime utcNow,
    int size = 30,
  }) {
    final ranked = _rank(taste, pool);
    final ids = _interleaveArtists(ranked, size);
    return GeneratedMix(
      kind: GeneratedMixKind.discoverWeekly,
      id: 'discover-weekly-${dailySeed(utcNow)}',
      title: 'Discover Weekly',
      trackIds: ids,
    );
  }

  GeneratedMix dailyMix({
    required UserTasteModel taste,
    required List<TasteSignal> pool,
    required int index,
    required DateTime utcNow,
    int size = 50,
  }) {
    final slot = index < 1 ? 1 : (index > 5 ? 5 : index);
    final genres = taste.genreAffinity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final focus = genres.isEmpty
        ? ''
        : genres[(slot - 1) % genres.length].key;
    final filtered = focus.isEmpty
        ? pool
        : pool.where((s) => s.genre == focus).toList();
    final source = filtered.isEmpty ? pool : filtered;
    final ranked = _rank(taste, source);
    return GeneratedMix(
      kind: GeneratedMixKind.dailyMix,
      id: 'daily-mix-$slot-${dailySeed(utcNow)}',
      title: focus.isEmpty ? 'Daily Mix $slot' : 'Daily Mix $slot · $focus',
      trackIds: _take(ranked, size),
    );
  }

  GeneratedMix moodMix({
    required String mood,
    required UserTasteModel taste,
    required List<TasteSignal> pool,
    int size = 40,
  }) {
    final ranked = _rank(taste, pool);
    return GeneratedMix(
      kind: GeneratedMixKind.moodMix,
      id: 'mood-${mood.toLowerCase()}',
      title: '$mood Mix',
      trackIds: _take(ranked, size),
    );
  }

  GeneratedMix artistMix({
    required String artistId,
    required String artistName,
    required UserTasteModel taste,
    required List<TasteSignal> pool,
    int size = 40,
  }) {
    final ofArtist = pool.where((s) => s.artistId == artistId).toList();
    final ranked = _rank(taste, ofArtist.isEmpty ? pool : ofArtist);
    return GeneratedMix(
      kind: GeneratedMixKind.artistMix,
      id: 'artist-mix-$artistId',
      title: 'This is $artistName',
      trackIds: _take(ranked, size),
    );
  }

  List<TasteSignal> _rank(UserTasteModel taste, List<TasteSignal> pool) {
    final copy = List<TasteSignal>.of(pool)
      ..sort((a, b) {
        final byAff = taste
            .affinityFor(b.trackId)
            .compareTo(taste.affinityFor(a.trackId));
        if (byAff != 0) return byAff;
        return b.playCount.compareTo(a.playCount);
      });
    return copy;
  }

  List<String> _take(List<TasteSignal> ranked, int size) {
    final ids = <String>[];
    final seen = <String>{};
    for (final signal in ranked) {
      if (ids.length >= size) break;
      if (!seen.add(signal.trackId)) continue;
      ids.add(signal.trackId);
    }
    return List<String>.unmodifiable(ids);
  }

  /// Round-robin across artists so Discover Weekly is not one-artist.
  List<String> _interleaveArtists(List<TasteSignal> ranked, int size) {
    final byArtist = <String, List<TasteSignal>>{};
    for (final signal in ranked) {
      byArtist.putIfAbsent(signal.artistId, () => <TasteSignal>[]).add(signal);
    }
    final artists = byArtist.keys.toList();
    final ids = <String>[];
    final seen = <String>{};
    var lane = 0;
    final cursor = <String, int>{for (final a in artists) a: 0};
    while (ids.length < size && artists.isNotEmpty) {
      final artist = artists[lane % artists.length];
      final tracks = byArtist[artist]!;
      final index = cursor[artist]!;
      if (index >= tracks.length) {
        artists.removeAt(lane % artists.length);
        if (artists.isEmpty) break;
        continue;
      }
      cursor[artist] = index + 1;
      lane++;
      final id = tracks[index].trackId;
      if (!seen.add(id)) continue;
      ids.add(id);
    }
    return List<String>.unmodifiable(ids);
  }
}
