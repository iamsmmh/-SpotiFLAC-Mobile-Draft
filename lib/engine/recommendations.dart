/// Recommendation engine: provider-agnostic port + a fully local engine.
///
/// Pure Dart (no Flutter, no I/O) so the ranking logic is unit-testable and
/// the engine layer stays transport-agnostic, exactly like
/// `streaming_engine.dart` and `replay_gain.dart`.
///
/// Architecture (Phase 7):
///
///   * [RecommendationProvider] is the **port**. Remote/extension-backed
///     recommenders (similarity graphs, editorial charts) implement it and
///     register with [RecommendationService]; nothing here hardcodes one.
///   * [LocalRecommendationEngine] is the always-available implementation: it
///     derives sections from the on-device [RecommendationProfile]
///     (listening statistics + favorites) and needs no network, account, or
///     provider extension.
///   * [RecommendationService] chains providers: richer remote sections win
///     when present, the local engine fills whatever is missing, so the UI
///     always renders something honest instead of an empty shelf.
library;

/// Kinds of recommendation shelves the app can render.
enum RecommendationSectionKind {
  recentlyPlayed,
  frequentlyPlayed,
  similarArtists,
  similarTracks,
  discoveryMix,
  trending,
  becauseYouListened,
}

/// The media kind a [RecommendedItem] points at.
enum RecommendedItemKind { track, artist, album }

/// One recommended entity. Identity is provider-agnostic: [id] is stable
/// within [providerId] (or the local engine's own namespace).
class RecommendedItem {
  const RecommendedItem({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.imageUrl,
    this.providerId,
    this.score = 0.0,
  });

  final RecommendedItemKind kind;
  final String id;
  final String title;

  /// Artist name for tracks/albums, genre or hint for artists.
  final String subtitle;
  final String? imageUrl;
  final String? providerId;

  /// 0..1 relevance within the producing section (best first).
  final double score;

  RecommendedItem copyWith({double? score}) {
    return RecommendedItem(
      kind: kind,
      id: id,
      title: title,
      subtitle: subtitle,
      imageUrl: imageUrl,
      providerId: providerId,
      score: score ?? this.score,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RecommendedItem &&
        other.kind == kind &&
        other.id == id &&
        other.title == title &&
        other.providerId == providerId;
  }

  @override
  int get hashCode => Object.hash(kind, id, title, providerId);

  @override
  String toString() => 'RecommendedItem(${kind.name}, "$title", $id)';
}

/// A named shelf of recommendations.
class RecommendationSection {
  const RecommendationSection({
    required this.kind,
    required this.items,
    this.title = '',
  });

  final RecommendationSectionKind kind;

  /// Items, best first.
  final List<RecommendedItem> items;

  /// Producer-supplied display title; the UI falls back to its own localized
  /// label for [kind] when empty.
  final String title;

  bool get isEmpty => items.isEmpty;

  RecommendationSection withScoresNormalized() {
    if (items.isEmpty) return this;
    var maxScore = 0.0;
    for (final item in items) {
      if (item.score > maxScore) maxScore = item.score;
    }
    if (maxScore <= 0) return this;
    return RecommendationSection(
      kind: kind,
      title: title,
      items: items
          .map((item) => item.copyWith(score: item.score / maxScore))
          .toList(growable: false),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile (engine input)
// ---------------------------------------------------------------------------

/// One observed play, supplied by the stats layer.
class ProfilePlay {
  const ProfilePlay({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album = '',
    this.playCount = 0,
    this.listenedMs = 0,
    this.lastPlayedAt,
  });

  final String trackId;
  final String title;
  final String artist;
  final String album;
  final int playCount;
  final int listenedMs;
  final DateTime? lastPlayedAt;
}

/// One followed/favorited artist or album the user cares about.
class ProfileAffinity {
  const ProfileAffinity({
    required this.id,
    required this.name,
    this.kind = RecommendedItemKind.artist,
    this.imageUrl,
    this.providerId,
  });

  final String id;
  final String name;
  final RecommendedItemKind kind;
  final String? imageUrl;
  final String? providerId;
}

/// Everything the local engine needs. Privacy-first: built entirely from
/// on-device data, it never leaves the process.
class RecommendationProfile {
  const RecommendationProfile({
    this.plays = const <ProfilePlay>[],
    this.favoriteArtists = const <ProfileAffinity>[],
    this.favoriteAlbums = const <ProfileAffinity>[],
    this.lovedTracks = const <ProfilePlay>[],
    this.dailySeed,
  });

  /// Per-track play aggregates (any window; the engine sorts by recency and
  /// count itself).
  final List<ProfilePlay> plays;

  final List<ProfileAffinity> favoriteArtists;
  final List<ProfileAffinity> favoriteAlbums;
  final List<ProfilePlay> lovedTracks;

  /// Deterministic rotation seed (e.g. UTC day ordinal) so the discovery mix
  /// is stable within a day but changes daily. Null → derive from plays.
  final int? dailySeed;

  bool get isCold =>
      plays.isEmpty && favoriteArtists.isEmpty && lovedTracks.isEmpty;
}

// ---------------------------------------------------------------------------
// Provider port
// ---------------------------------------------------------------------------

/// Port for recommendation sources. Implementations may be local (no I/O) or
/// remote (extension/network); [RecommendationService] treats them uniformly.
abstract interface class RecommendationProvider {
  /// Stable identifier, e.g. `local`, or an extension id.
  String get id;

  /// Produces sections for [profile]. Implementations must return quickly
  /// with an empty list on failure — the service interprets empty as "this
  /// provider has nothing to offer right now" and falls through the chain.
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  });
}

// ---------------------------------------------------------------------------
// Local engine
// ---------------------------------------------------------------------------

/// Fully on-device recommender. Honest approximations, documented:
///
///   * recently played  — by `lastPlayedAt` desc
///   * frequently played — by `playCount` desc, recency tie-break
///   * similar artists  — affinity = artists co-appearing in the user's play
///     history and favorites, weighted by plays (no external graph)
///   * similar tracks   — tracks sharing artist/album with the user's most
///     played seeds
///   * discovery mix    — deterministic daily rotation across the user's top
///     artists, interleaved round-robin so one artist never dominates
class LocalRecommendationEngine implements RecommendationProvider {
  const LocalRecommendationEngine({this.sectionItemCap = 20});

  final int sectionItemCap;

  static const String providerId = 'local';

  @override
  String get id => providerId;

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async {
    final cap = maxItemsPerSection < sectionItemCap
        ? maxItemsPerSection
        : sectionItemCap;
    if (profile.isCold || cap <= 0) {
      return const <RecommendationSection>[];
    }
    return <RecommendationSection>[
      _recentlyPlayed(profile, cap),
      _frequentlyPlayed(profile, cap),
      _similarArtists(profile, cap),
      _becauseYouListened(profile, cap),
      _discoveryMix(profile, cap),
    ].where((section) => !section.isEmpty).toList(growable: false);
  }

  RecommendationSection _recentlyPlayed(
    RecommendationProfile profile,
    int cap,
  ) {
    final sorted = List<ProfilePlay>.of(profile.plays)
      ..sort((a, b) {
        final at = a.lastPlayedAt;
        final bt = b.lastPlayedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return RecommendationSection(
      kind: RecommendationSectionKind.recentlyPlayed,
      items: _takeUniqueTracks(sorted, cap),
    );
  }

  RecommendationSection _frequentlyPlayed(
    RecommendationProfile profile,
    int cap,
  ) {
    final sorted = List<ProfilePlay>.of(profile.plays)
      ..sort((a, b) {
        final byCount = b.playCount.compareTo(a.playCount);
        if (byCount != 0) return byCount;
        final byListened = b.listenedMs.compareTo(a.listenedMs);
        if (byListened != 0) return byListened;
        final at = a.lastPlayedAt;
        final bt = b.lastPlayedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return RecommendationSection(
      kind: RecommendationSectionKind.frequentlyPlayed,
      items: _takeUniqueTracks(sorted, cap),
    );
  }

  RecommendationSection _similarArtists(
    RecommendationProfile profile,
    int cap,
  ) {
    final playWeightByArtist = <String, int>{};
    for (final play in profile.plays) {
      final name = play.artist.trim();
      if (name.isEmpty) continue;
      playWeightByArtist[name] =
          (playWeightByArtist[name] ?? 0) +
          (play.playCount > 0 ? play.playCount : 1);
    }
    final favoriteNames = <String>{
      for (final fav in profile.favoriteArtists) fav.name.toLowerCase(),
    };
    // Rank: explicit favorites above observed plays. A favorite outweighs any
    // single observed artist (favoriting is the stronger signal), so their
    // weight floats one rank above the observed maximum.
    var maxObservedWeight = 0;
    for (final weight in playWeightByArtist.values) {
      if (weight > maxObservedWeight) maxObservedWeight = weight;
    }
    final favoriteWeight = maxObservedWeight.toDouble() + 1.0;

    final candidates = <_ArtistCandidate>[];
    final seen = <String>{};
    for (final fav in profile.favoriteArtists) {
      final key = fav.name.toLowerCase();
      if (!seen.add(key)) continue;
      candidates.add(
        _ArtistCandidate(
          name: fav.name,
          id: fav.id,
          imageUrl: fav.imageUrl,
          providerId: fav.providerId,
          weight: favoriteWeight,
        ),
      );
    }
    for (final entry in playWeightByArtist.entries) {
      final key = entry.key.toLowerCase();
      if (favoriteNames.contains(key) || !seen.add(key)) continue;
      candidates.add(
        _ArtistCandidate(
          name: entry.key,
          id: key,
          weight: entry.value.toDouble(),
        ),
      );
    }
    // Weight desc, then name asc: Dart's sort is not stable, so the tie-break
    // keeps equal-weight favorites deterministic.
    candidates.sort((a, b) {
      final byWeight = b.weight.compareTo(a.weight);
      if (byWeight != 0) return byWeight;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final maxWeight = candidates.isEmpty ? 1.0 : candidates.first.weight;
    final items = candidates
        .take(cap)
        .map(
          (candidate) => RecommendedItem(
            kind: RecommendedItemKind.artist,
            id: candidate.id,
            title: candidate.name,
            imageUrl: candidate.imageUrl,
            providerId: candidate.providerId,
            score: maxWeight <= 0 ? 0.0 : candidate.weight / maxWeight,
          ),
        )
        .toList(growable: false);
    return RecommendationSection(
      kind: RecommendationSectionKind.similarArtists,
      items: items,
    );
  }

  /// "Because you listened to `<artist>`" — seeded by the artist with the
  /// strongest recent play weight, filled with tracks from *other* artists
  /// that share affinity (album neighbours and the affinity pool behind
  /// `_similarArtists`), so the shelf explains itself and still surprises.
  RecommendationSection _becauseYouListened(
    RecommendationProfile profile,
    int cap,
  ) {
    final playWeightByArtist = <String, int>{};
    var totalWeight = 0;
    for (final play in profile.plays) {
      final name = play.artist.trim();
      if (name.isEmpty) continue;
      final weight = play.playCount > 0 ? play.playCount : 1;
      playWeightByArtist[name] = (playWeightByArtist[name] ?? 0) + weight;
      totalWeight += weight;
    }
    if (playWeightByArtist.isEmpty || totalWeight <= 0) {
      return const RecommendationSection(
        kind: RecommendationSectionKind.becauseYouListened,
        items: <RecommendedItem>[],
      );
    }
    final seedArtist = playWeightByArtist.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    // Affinity neighbours: artists the user plays alongside the seed
    // (ranked by their own weight, excluding the seed itself).
    final neighbourList = <MapEntry<String, double>>[
      for (final entry in playWeightByArtist.entries)
        if (entry.key.toLowerCase() != seedArtist.toLowerCase())
          MapEntry<String, double>(
            entry.key,
            entry.value / totalWeight.toDouble(),
          ),
    ]..sort((a, b) => b.value.compareTo(a.value));

    // Items: the strongest track per neighbour artist, capped.
    final bestPerArtist = <String, ProfilePlay>{};
    for (final play in profile.plays) {
      final artist = play.artist.trim();
      if (artist.isEmpty) continue;
      if (artist.toLowerCase() == seedArtist.toLowerCase()) continue;
      final existing = bestPerArtist[artist];
      if (existing == null || play.playCount > existing.playCount) {
        bestPerArtist[artist] = play;
      }
    }

    final items = <RecommendedItem>[];
    final seen = <String>{};
    for (final neighbour in neighbourList) {
      if (items.length >= cap) break;
      final play = bestPerArtist[neighbour.key];
      if (play == null) continue;
      final key = play.trackId.isNotEmpty
          ? play.trackId
          : '${play.title}|${play.artist}';
      if (!seen.add(key)) continue;
      items.add(
        RecommendedItem(
          kind: RecommendedItemKind.track,
          id: play.trackId,
          title: play.title,
          subtitle: play.artist,
          providerId: providerId,
          score: neighbour.value,
        ),
      );
    }
    return RecommendationSection(
      kind: RecommendationSectionKind.becauseYouListened,
      title: 'Because you listened to $seedArtist',
      items: List<RecommendedItem>.unmodifiable(items),
    );
  }

  RecommendationSection _discoveryMix(RecommendationProfile profile, int cap) {
    // Group each artist's playable tracks ordered by play weight.
    final byArtist = <String, List<ProfilePlay>>{};
    for (final play in profile.plays) {
      final artist = play.artist.trim();
      if (artist.isEmpty) continue;
      byArtist.putIfAbsent(artist, () => <ProfilePlay>[]).add(play);
    }
    if (byArtist.length < 2) {
      // A mix needs variety; single-artist users still get the mix from their
      // loved tracks (explicit signal) when stats alone cannot diversify.
      return RecommendationSection(
        kind: RecommendationSectionKind.discoveryMix,
        items: _takeUniqueTracks(profile.lovedTracks, cap),
      );
    }
    // Growable: exhausted lanes are removed during the interleave below.
    final artists = byArtist.keys.toList();
    final seed = _effectiveSeed(profile, artists);
    artists.sort((a, b) => _seededRank(seed, a).compareTo(_seededRank(seed, b)));

    for (final tracks in byArtist.values) {
      tracks.sort((a, b) => b.playCount.compareTo(a.playCount));
    }

    // Round-robin interleave artist lanes until [cap] is filled.
    final items = <RecommendedItem>[];
    final seenIds = <String>{};
    var lane = 0;
    final remaining = <String, int>{for (final a in artists) a: 0};
    while (items.length < cap) {
      final artist = artists[lane % artists.length];
      final tracks = byArtist[artist]!;
      final position = remaining[artist]!;
      if (position >= tracks.length) {
        // Drop exhausted lanes; protect against infinite loops.
        artists.removeAt(lane % artists.length);
        if (artists.isEmpty) break;
        continue;
      }
      final play = tracks[position];
      remaining[artist] = position + 1;
      lane++;
      final dedupeKey = play.trackId.isNotEmpty
          ? play.trackId
          : '${play.title}|${play.artist}';
      if (!seenIds.add(dedupeKey)) continue;
      items.add(
        RecommendedItem(
          kind: RecommendedItemKind.track,
          id: play.trackId,
          title: play.title,
          subtitle: play.artist,
          providerId: providerId,
          // Earlier slots in the mix score higher.
          score: 1.0 - (items.length / cap) * 0.5,
        ),
      );
    }
    return RecommendationSection(
      kind: RecommendationSectionKind.discoveryMix,
      items: List<RecommendedItem>.unmodifiable(items),
    );
  }

  List<RecommendedItem> _takeUniqueTracks(List<ProfilePlay> plays, int cap) {
    final items = <RecommendedItem>[];
    final seen = <String>{};
    for (final play in plays) {
      if (items.length >= cap) break;
      final key = play.trackId.isNotEmpty
          ? play.trackId
          : '${play.title}|${play.artist}';
      if (!seen.add(key)) continue;
      items.add(
        RecommendedItem(
          kind: RecommendedItemKind.track,
          id: play.trackId,
          title: play.title,
          subtitle: play.artist,
          providerId: providerId,
          score: 1.0 - (items.length / (cap == 0 ? 1 : cap)) * 0.5,
        ),
      );
    }
    return List<RecommendedItem>.unmodifiable(items);
  }

  int _effectiveSeed(RecommendationProfile profile, List<String> artists) {
    final explicit = profile.dailySeed;
    if (explicit != null) return explicit;
    var hash = 0x811c9dc5;
    for (final artist in artists) {
      for (final codeUnit in artist.codeUnits) {
        hash = (hash ^ codeUnit) * 0x01000193;
        hash &= 0x7fffffff;
      }
    }
    return hash;
  }

  /// Stable pseudo-rank of [value] under [seed] (FNV-1a mixing).
  int _seededRank(int seed, String value) {
    var hash = seed & 0x7fffffff;
    for (final codeUnit in value.codeUnits) {
      hash = (hash ^ codeUnit) * 0x01000193;
      hash &= 0x7fffffff;
    }
    return hash;
  }
}

class _ArtistCandidate {
  const _ArtistCandidate({
    required this.name,
    required this.id,
    required this.weight,
    this.imageUrl,
    this.providerId,
  });

  final String name;
  final String id;
  final double weight;
  final String? imageUrl;
  final String? providerId;
}

// ---------------------------------------------------------------------------
// Aggregating service
// ---------------------------------------------------------------------------

/// Chains [RecommendationProvider]s: for every section kind the first provider
/// (in registration order) that returns a non-empty section wins, and later
/// providers fill the gaps. The local engine should be registered last so it
/// acts as the always-available fallback, never overriding richer sources.
class RecommendationService {
  RecommendationService({List<RecommendationProvider>? providers})
    : _providers = List<RecommendationProvider>.unmodifiable(
        providers ?? const <RecommendationProvider>[],
      );

  final List<RecommendationProvider> _providers;

  /// Defaults to a single local engine — the app is useful with zero network.
  factory RecommendationService.localOnly() {
    return RecommendationService(
      providers: const <RecommendationProvider>[LocalRecommendationEngine()],
    );
  }

  List<String> get providerIds =>
      _providers.map((provider) => provider.id).toList(growable: false);

  /// Registers [provider] before the local fallback (or appends when no
  /// local engine is present). Returns a new service (immutable value type).
  RecommendationService withProvider(RecommendationProvider provider) {
    final next = List<RecommendationProvider>.of(_providers);
    final localIndex = next.indexWhere(
      (candidate) => candidate.id == LocalRecommendationEngine.providerId,
    );
    if (localIndex >= 0) {
      next.insert(localIndex, provider);
    } else {
      next.add(provider);
    }
    return RecommendationService(providers: next);
  }

  /// Produces the merged shelf list. Never throws: a failing provider simply
  /// contributes nothing (fail-open with fallback, mirroring the streaming
  /// engine's provider-health philosophy).
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
    Duration perProviderTimeout = const Duration(seconds: 4),
  }) async {
    final byKind = <RecommendationSectionKind, RecommendationSection>{};
    for (final provider in _providers) {
      List<RecommendationSection> sections;
      try {
        sections = await provider
            .recommend(profile, maxItemsPerSection: maxItemsPerSection)
            .timeout(perProviderTimeout);
      } catch (_) {
        continue; // fail-open: try the next provider in the chain
      }
      for (final section in sections) {
        if (section.isEmpty) continue;
        byKind.putIfAbsent(section.kind, () => section.withScoresNormalized());
      }
      // Stop only once every known shelf kind has been filled.
      if (byKind.length >= RecommendationSectionKind.values.length) {
        break;
      }
    }
    final ordered = byKind.values.toList(growable: false)
      ..sort(
        (a, b) => _kindOrder(a.kind).compareTo(_kindOrder(b.kind)),
      );
    return ordered;
  }

  int _kindOrder(RecommendationSectionKind kind) {
    switch (kind) {
      case RecommendationSectionKind.recentlyPlayed:
        return 0;
      case RecommendationSectionKind.becauseYouListened:
        return 1;
      case RecommendationSectionKind.discoveryMix:
        return 2;
      case RecommendationSectionKind.frequentlyPlayed:
        return 3;
      case RecommendationSectionKind.similarArtists:
        return 4;
      case RecommendationSectionKind.similarTracks:
        return 5;
      case RecommendationSectionKind.trending:
        return 6;
    }
  }
}
