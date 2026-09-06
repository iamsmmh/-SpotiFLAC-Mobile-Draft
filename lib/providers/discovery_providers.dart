/// Riverpod wiring for the discovery / recommendation suite (Phase 11).
///
/// Follows the repository's convention (`providers/ecosystem_providers.dart`):
/// providers are thin — they compose services and expose immutable state, and
/// every piece of logic lives in `lib/engine/discovery/**` (pure maths) or
/// `lib/ecosystem/discovery/**` (persistence + orchestration).
///
/// Dependency injection is explicit: [discoveryServiceProvider] constructs every
/// collaborator and hands it down, so swapping an implementation (a remote
/// recommender, a different scorer, an in-memory cache for tests) is a single
/// override at the composition root — no service reaches for a singleton.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/ecosystem/discovery/continue_listening_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_service.dart';
import 'package:spotiflac_android/ecosystem/discovery/radio_service.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_engine.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/trending_repository.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';
import 'package:spotiflac_android/engine/discovery/radio_engine.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';
import 'package:spotiflac_android/engine/discovery/trending_engine.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';

// ---------------------------------------------------------------------------
// Collections projection
// ---------------------------------------------------------------------------

/// Projects favorites and playlists out of the collections store into the
/// plain data shape the discovery repository consumes.
///
/// Both key namespaces are carried for loved tracks: the collection key
/// (`isrc:…` / `source:id`) *and* the discovery key (`isrc:…` / `ta:title|artist`),
/// so a match never depends on which namespace a caller happens to use.
DiscoveryLibraryInput buildDiscoveryLibraryInput(
  LibraryCollectionsState collections,
) {
  final favoriteTrackKeys = <String>{};
  final favoriteTracks = <DiscoveryTrack>[];
  for (final entry in collections.loved) {
    final track = discoveryTrackFrom(
      id: entry.track.id,
      name: entry.track.name,
      artistName: entry.track.artistName,
      albumName: entry.track.albumName,
      coverUrl: entry.track.coverUrl,
      isrc: entry.track.isrc,
      durationSeconds: entry.track.duration,
      genre: entry.track.genre,
      comment: entry.track.comment,
      releaseDate: entry.track.releaseDate,
      providerId: entry.track.source,
      isFavorite: true,
    );
    favoriteTrackKeys.add(entry.key);
    favoriteTrackKeys.add(track.key);
    favoriteTracks.add(track);
  }

  final playlistIdsByTrackKey = <String, Set<String>>{};
  final playlistTrackKeys = <Set<String>>[];
  final playlistNames = <String, String>{};
  for (final playlist in collections.playlists) {
    playlistNames[playlist.id] = playlist.name;
    final keys = <String>{};
    for (final entry in playlist.tracks) {
      final track = discoveryTrackFrom(
        id: entry.track.id,
        name: entry.track.name,
        artistName: entry.track.artistName,
        albumName: entry.track.albumName,
        coverUrl: entry.track.coverUrl,
        isrc: entry.track.isrc,
        durationSeconds: entry.track.duration,
        genre: entry.track.genre,
        providerId: entry.track.source,
      );
      keys.add(track.key);
      keys.add(entry.key);
      final bucket = playlistIdsByTrackKey.putIfAbsent(
        track.key,
        () => <String>{},
      );
      bucket.add(playlist.id);
      final aliasBucket = playlistIdsByTrackKey.putIfAbsent(
        entry.key,
        () => <String>{},
      );
      aliasBucket.add(playlist.id);
    }
    playlistTrackKeys.add(keys);
  }

  return DiscoveryLibraryInput(
    favoriteTrackKeys: Set<String>.unmodifiable(favoriteTrackKeys),
    favoriteTracks: List<DiscoveryTrack>.unmodifiable(favoriteTracks),
    favoriteArtistKeys: Set<String>.unmodifiable(<String>{
      for (final entry in collections.favoriteArtists)
        discoveryEntityKey(entry.name),
    }),
    favoriteAlbumKeys: Set<String>.unmodifiable(<String>{
      for (final entry in collections.favoriteAlbums)
        discoveryEntityKey('${entry.name}|${entry.artistName ?? ''}'),
    }),
    playlistIdsByTrackKey: Map<String, Set<String>>.unmodifiable(
      playlistIdsByTrackKey,
    ),
    playlistTrackKeys: List<Set<String>>.unmodifiable(playlistTrackKeys),
    playlistNames: Map<String, String>.unmodifiable(playlistNames),
  );
}

/// The current projection. Kept as its own provider so the radio and the
/// service read one value rather than recomputing it.
final discoveryLibraryInputProvider = Provider<DiscoveryLibraryInput>((ref) {
  return buildDiscoveryLibraryInput(ref.watch(libraryCollectionsProvider));
});

// ---------------------------------------------------------------------------
// Pool source
// ---------------------------------------------------------------------------

/// Adapts the Riverpod container to the [RadioPoolSource] port, so the radio
/// service and the discovery service share one pool instead of each building
/// its own.
class RiverpodPoolSource implements RadioPoolSource {
  RiverpodPoolSource(this._read);

  final DiscoveryLibraryInput Function() _read;
  final RecommendationRepository _repository = RecommendationRepository();

  @override
  Future<DiscoveryCandidatePool> loadPool() {
    return _repository.loadPool(input: _read());
  }
}

final discoveryPoolSourceProvider = Provider<RiverpodPoolSource>((ref) {
  return RiverpodPoolSource(() => ref.read(discoveryLibraryInputProvider));
});

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// The discovery orchestrator. One instance for the app's lifetime.
final discoveryServiceProvider = Provider<DiscoveryService>((ref) {
  final service = DiscoveryService(
    inputProvider: () async => ref.read(discoveryLibraryInputProvider),
    poolSource: ref.watch(discoveryPoolSourceProvider),
  );
  return service;
});

/// The personalised home payload (Phase 10).
///
/// `keepAlive` by default: the shelves are the app's front door, and throwing
/// them away on every navigation would re-run the whole pass.
final discoveryHomeProvider = FutureProvider<DiscoveryHome>((ref) async {
  return ref.watch(discoveryServiceProvider).home();
});

/// Forces a regeneration (pull-to-refresh).
Future<DiscoveryHome> refreshDiscovery(WidgetRef ref) {
  return ref.read(discoveryServiceProvider).home(force: true);
}

/// Diagnostics for the settings screen (Phase 12 observability).
final discoveryDiagnosticsProvider = FutureProvider<DiscoveryDiagnostics>((
  ref,
) async {
  return ref.watch(discoveryServiceProvider).diagnostics();
});

// ---------------------------------------------------------------------------
// Individual shelves
// ---------------------------------------------------------------------------

/// One Daily Mix, or null when the day's mixes are not generated yet.
final dailyMixProvider = FutureProvider.family<GeneratedShelf?, int>((
  ref,
  position,
) async {
  final home = await ref.watch(discoveryHomeProvider.future);
  if (position < 0 || position >= home.dailyMixes.length) return null;
  return home.dailyMixes[position];
});

/// One mood shelf.
final moodShelfProvider = FutureProvider.family<GeneratedShelf?, String>((
  ref,
  moodName,
) async {
  final home = await ref.watch(discoveryHomeProvider.future);
  for (final entry in home.moods.entries) {
    if (entry.key.name == moodName) return entry.value;
  }
  return null;
});

/// Catalogue of moods the UI can offer, whether or not a shelf exists yet.
final moodCatalogueProvider = Provider<List<MoodProfile>>((ref) {
  return <MoodProfile>[for (final mood in allMoods) moodProfiles[mood]!];
});

/// One trending shelf.
final trendingShelfProvider =
    FutureProvider.family<List<TrendingEntry>, String>((ref, periodName) async {
      final home = await ref.watch(discoveryHomeProvider.future);
      for (final period in TrendingPeriod.values) {
        if (period.name != periodName) continue;
        switch (period) {
          case TrendingPeriod.week:
            return home.trendingWeek;
          case TrendingPeriod.month:
            return home.trendingMonth;
          case TrendingPeriod.velocity:
            return home.fastestGrowing;
          case TrendingPeriod.emerging:
            return home.emergingArtists;
        }
      }
      return const <TrendingEntry>[];
    });

/// Similar artists for one artist key (Phase 6).
final similarArtistsProvider =
    FutureProvider.family<List<ArtistSimilarity>, String>((
      ref,
      artistKey,
    ) async {
      return ref.watch(discoveryServiceProvider).similarArtistsFor(artistKey);
    });

/// Top tracks and albums for one artist key.
final artistDetailProvider = FutureProvider.family<ArtistDetail, String>((
  ref,
  artistKey,
) async {
  return ref.watch(discoveryServiceProvider).artistDetail(artistKey);
});

/// The continue-listening resume point.
final continueListeningProvider =
    FutureProvider<ContinueListeningEntry?>((ref) async {
      final home = await ref.watch(discoveryHomeProvider.future);
      return home.continueListening;
    });

/// Open and recent radio stations.
final radioStationsProvider = FutureProvider<List<RadioStationSummary>>((
  ref,
) async {
  return ref.watch(discoveryServiceProvider).radio.stations();
});

// ---------------------------------------------------------------------------
// Radio session
// ---------------------------------------------------------------------------

/// Live radio state. Null when no station is running.
class RadioSessionController extends Notifier<RadioState?> {
  @override
  RadioState? build() => null;

  DiscoveryService get _service => ref.read(discoveryServiceProvider);

  Future<void> startArtist({
    required String artistKey,
    required String label,
  }) async {
    state = await _service.radio.startArtistRadio(
      artistKey: artistKey,
      label: label,
    );
  }

  Future<void> startTrack({required String trackKey}) async {
    state = await _service.radio.startTrackRadio(trackKey: trackKey);
  }

  Future<void> startGenre({required String genre, String? label}) async {
    state = await _service.radio.startGenreRadio(genre: genre, label: label);
  }

  Future<void> startMood({required Mood mood}) async {
    state = await _service.radio.startMoodRadio(mood: mood);
  }

  Future<void> resume(String sessionId) async {
    state = await _service.radio.resume(sessionId);
  }

  /// Records the outcome of the track that just ended and keeps the queue full.
  Future<void> advance({required bool skipped}) async {
    final current = state;
    if (current == null) return;
    final next = current.queue.isEmpty ? null : current.queue.first.track.key;
    if (next == null) return;
    var updated = await _service.radio.noteOutcome(
      current,
      next,
      skipped: skipped,
    );
    updated = await _service.radio.ensureQueue(updated);
    state = updated;
  }

  /// Tops the queue up without consuming a track.
  Future<void> refill() async {
    final current = state;
    if (current == null) return;
    state = await _service.radio.ensureQueue(current);
  }

  Future<void> stop() async {
    final current = state;
    state = null;
    if (current != null) {
      await _service.radio.close(current.sessionId);
    }
  }
}

final radioSessionProvider =
    NotifierProvider<RadioSessionController, RadioState?>(
      RadioSessionController.new,
    );

// ---------------------------------------------------------------------------
// Continue-listening recorder
// ---------------------------------------------------------------------------

/// Captures resume points from playback without touching the audio handler.
///
/// It observes the two streams the player already publishes — the current media
/// item and the playing flag — and asks the controller for the position when a
/// track ends or playback pauses. That keeps `music_player_service.dart`
/// (playback, gapless, crossfade, media buttons) completely untouched, which is
/// the "do not break playback" constraint taken literally.
class ContinueListeningRecorder {
  ContinueListeningRecorder({
    required this.readEntry,
    required this.write,
    required this.position,
  });

  /// Reads the currently playing item, if any.
  final PlayingItem? Function() readEntry;

  final Future<void> Function(ContinueListeningEntry entry) write;

  /// Current playback offset, or null when unknown.
  final Future<Duration?> Function() position;

  PlayingItem? _tracked;

  /// Call when the playing item or the playing flag changes.
  Future<void> observe({required bool isPlaying}) async {
    final current = readEntry();
    final previous = _tracked;

    if (previous != null &&
        (current == null || current.mediaId != previous.mediaId)) {
      await _persist(previous);
    }
    _tracked = current;

    if (!isPlaying && current != null) {
      await _persist(current);
    }
  }

  Future<void> flush() async {
    final current = _tracked;
    if (current != null) await _persist(current);
  }

  Future<void> _persist(PlayingItem item) async {
    final elapsed = await position();
    final positionMs = elapsed?.inMilliseconds ?? 0;
    final track = discoveryTrackFrom(
      id: item.mediaId,
      name: item.title,
      artistName: item.artist,
      albumName: item.album,
      coverUrl: item.artUri,
      durationSeconds: item.durationMs ~/ 1000,
      localPath: item.isLocal ? item.extras?['path']?.toString() : null,
    );
    await write(
      ContinueListeningEntry(
        slot: primaryContinueSlot,
        kind: item.contextId.isEmpty
            ? ContinueContextKind.track
            : ContinueContextKind.queue,
        track: track,
        positionMs: positionMs,
        durationMs: item.durationMs,
        contextId: item.contextId,
        contextLabel: item.contextLabel,
        updatedAt: DateTime.now(),
      ),
    );
  }
}

/// The minimum the recorder needs about the playing item.
class PlayingItem {
  const PlayingItem({
    required this.mediaId,
    required this.title,
    required this.artist,
    required this.album,
    this.artUri,
    this.durationMs = 0,
    this.isLocal = false,
    this.contextId = '',
    this.contextLabel = '',
    this.extras,
  });

  final String mediaId;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final int durationMs;
  final bool isLocal;
  final String contextId;
  final String contextLabel;
  final Map<String, Object?>? extras;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// The subscriptions [installDiscoveryRecording] owns. Kept in one object so
/// the caller can close them all on teardown.
class DiscoverySubscriptions {
  DiscoverySubscriptions(this._subscriptions);

  final List<ProviderSubscription<Object?>> _subscriptions;

  void close() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
  }
}

/// Installs the background refresh + continue-listening hooks.
///
/// Called once from app bootstrap (`main.dart`), next to
/// `installPlaybackStatisticsRecording`. Everything here is deliberately
/// non-blocking and debounced inside [DiscoveryService], so wiring it to app
/// resume and to every completed play cannot storm the CPU or the disk.
///
/// Playback itself is untouched: the recorder only *reads* the streams the
/// audio handler already publishes.
DiscoverySubscriptions installDiscoveryRecording(WidgetRef ref) {
  final service = ref.read(discoveryServiceProvider);
  final subscriptions = <ProviderSubscription<Object?>>[];

  // Warm the pipeline without blocking startup: the first paint renders the
  // onboarding state and swaps the shelves in when the pass lands.
  unawaited(service.home());

  // A completed play changes the profile; schedule (not await) a refresh.
  subscriptions.add(
    ref.listenManual<int>(playbackTickProvider, (_, _) {
      service.scheduleRefresh();
    }),
  );

  // Library or favorites changed → the candidate pool is stale.
  subscriptions.add(
    ref.listenManual<LibraryCollectionsState>(
      libraryCollectionsProvider,
      (_, _) {
        service.invalidate();
        service.scheduleRefresh();
      },
    ),
  );

  // ---- Continue Listening (Phase 8) --------------------------------------
  final recorder = ContinueListeningRecorder(
    readEntry: () => _currentPlayingItem(ref),
    write: (entry) => service.continueListening.savePrimary(entry),
    position: () =>
        ref.read(musicPlayerControllerProvider).currentPlaybackPosition(),
  );

  var lastPlaying = false;
  subscriptions.add(
    ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (_, _) {
        unawaited(recorder.observe(isPlaying: lastPlaying));
      },
    ),
  );
  subscriptions.add(
    ref.listenManual<bool>(playbackPlayingProvider, (_, next) {
      lastPlaying = next;
      unawaited(recorder.observe(isPlaying: next));
    }),
  );

  return DiscoverySubscriptions(subscriptions);
}

/// Projects the player's current [MediaItem] into the recorder's input shape.
PlayingItem? _currentPlayingItem(WidgetRef ref) {
  final item = ref.read(currentMediaItemProvider).value;
  if (item == null) return null;
  final title = item.title ?? '';
  final artist = item.artist ?? '';
  if (title.isEmpty && artist.isEmpty) return null;
  final source = item.extras?['source']?.toString() ?? '';
  return PlayingItem(
    mediaId: item.id,
    title: title,
    artist: artist,
    album: item.album ?? '',
    artUri: item.artUri?.toString(),
    durationMs: item.duration?.inMilliseconds ?? 0,
    isLocal: source.isNotEmpty && !source.startsWith('http'),
    extras: item.extras,
  );
}

// ---------------------------------------------------------------------------
// Playback ticks
// ---------------------------------------------------------------------------

/// Bumped by the playback observer on every completed track. A dedicated
/// signal (rather than watching the whole statistics map) keeps the discovery
/// listener cheap.
final playbackTickProvider = NotifierProvider<PlaybackTickController, int>(
  PlaybackTickController.new,
);

class PlaybackTickController extends Notifier<int> {
  @override
  int build() => 0;

  void tick() => state = state + 1;
}
