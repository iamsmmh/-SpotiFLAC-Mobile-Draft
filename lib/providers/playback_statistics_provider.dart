import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/engine/track_identity.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

/// Privacy-first listening statistics.
///
/// Data stays on the device and is only written when
/// `EngineSettings.trackListeningStats` is enabled. The provider exposes the
/// accumulated [ListeningStats] (totals + per-track plays) and installs the
/// [PlaybackStatsObserver] so every local/stream playback start and completion
/// is recorded without coupling the audio handler to Riverpod.
final playbackStatisticsProvider = NotifierProvider<
    PlaybackStatisticsNotifier,
    ListeningStats>(PlaybackStatisticsNotifier.new);

class PlaybackStatisticsNotifier extends Notifier<ListeningStats> {
  static const String _key = 'engine_listening_stats_v1';

  @override
  ListeningStats build() => const ListeningStats();

  /// Loads persisted stats. Called once from app bootstrap; a corrupt store
  /// must never break startup.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        state = ListeningStats.fromJson(decoded);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  bool get _recordingEnabled =>
      ref.read(engineSettingsProvider).trackListeningStats;

  Future<void> _apply(ListeningStats next) async {
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.toJson()));
    } catch (_) {
      // Best-effort: a write failure must never interrupt playback.
    }
  }

  Future<void> recordTrackPlay(TrackPlayIdentity identity, {DateTime? at}) async {
    if (!_recordingEnabled) return;
    await _apply(state.recordTrackPlay(identity, at: at));
  }

  Future<void> recordTrackListen(
    TrackPlayIdentity identity,
    Duration elapsed, {
    DateTime? at,
  }) async {
    if (!_recordingEnabled) return;
    await _apply(state.recordTrackListen(identity, elapsed, at: at));
  }

  Future<void> recordSkip({DateTime? at}) async {
    if (!_recordingEnabled) return;
    await _apply(state.recordSkip(at: at));
  }

  /// Clears all listening statistics (totals + per-track + history).
  Future<void> resetAll() => _apply(const ListeningStats());
}

/// Installs the player observer (idempotent). Called from app bootstrap after
/// the engine settings are available; reading the notifier warms the provider.
///
/// [historyRepository] — when provided, the same observer also feeds the
/// ecosystem listening history (`ec_listening_events` + aggregates): one
/// `PlayEvent` per completed listen or skip, keyed by the canonical track
/// identity. Feature Group 7 (history) becomes live end-to-end without the
/// audio handler learning about SQLite.
void installPlaybackStatisticsRecording(
  WidgetRef ref, {
  ListeningHistoryRepository? historyRepository,
}) {
  final notifier = ref.read(playbackStatisticsProvider.notifier);
  setPlaybackStatsObserver(
    PlaybackStatsObserver(
      onStarted: (media) {
        unawaited(
          notifier.recordTrackPlay(
            TrackPlayIdentity(
              trackId: media.id,
              title: media.title,
              artist: media.artist,
              album: media.album,
            ),
          ),
        );
        _historyStartTimes[media.id] = DateTime.now();
      },
      onCompleted: (media, listened) {
        if (listened == null || listened <= Duration.zero) return;
        unawaited(
          notifier.recordTrackListen(
            TrackPlayIdentity(
              trackId: media.id,
              title: media.title,
              artist: media.artist,
              album: media.album,
            ),
            listened,
          ),
        );
        final repository = historyRepository;
        if (repository != null) {
          final startedAt = _historyStartTimes.remove(media.id) ?? DateTime.now();
          unawaited(
            repository.record(
              PlayEvent(
                trackKey: _historyKeyFor(media),
                title: media.title,
                artist: media.artist,
                album: media.album,
                coverUrl: media.artUri,
                durationMs: media.duration?.inMilliseconds ?? 0,
                playedMs: listened.inMilliseconds,
                startedAt: startedAt,
                endedAt: DateTime.now(),
                skipped: false,
                source: media.source.startsWith('http') ? 'stream' : 'local',
              ),
            ),
          );
        }
      },
      onSkip: (media) {
        unawaited(notifier.recordSkip());
        final repository = historyRepository;
        if (repository != null) {
          final startedAt = _historyStartTimes.remove(media.id) ?? DateTime.now();
          unawaited(
            repository.record(
              PlayEvent(
                trackKey: _historyKeyFor(media),
                title: media.title,
                artist: media.artist,
                album: media.album,
                coverUrl: media.artUri,
                durationMs: media.duration?.inMilliseconds ?? 0,
                playedMs: 0,
                startedAt: startedAt,
                endedAt: DateTime.now(),
                skipped: true,
                source: media.source.startsWith('http') ? 'stream' : 'local',
              ),
            ),
          );
        }
      },
    ),
  );
}

/// Start timestamps for the in-flight listen of each media id.
final Map<String, DateTime> _historyStartTimes = <String, DateTime>{};

/// Canonical history key: the same ISRC-first identity the engine and the
/// cache use, so history rows, cache entries and library lookups line up.
String _historyKeyFor(PlayableMedia media) => CanonicalTrackKey.fromInput(
      TrackIdentityInput(
        title: media.title,
        artist: media.artist,
        album: media.album,
      ),
    ).stableId;

/// Clears the observer (used in tests/disposal).
void uninstallPlaybackStatisticsRecording() {
  setPlaybackStatsObserver(null);
}

/// Formats stored milliseconds into a compact "Xh Ym" / "Ym" / "Ns" label.
String formatListenedMs(int totalMs) {
  if (totalMs <= 0) return '0m';
  final totalMinutes = totalMs ~/ 60000;
  if (totalMinutes < 60) return '${totalMinutes}m';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours < 24) return '${hours}h ${minutes}m';
  final days = hours ~/ 24;
  final restHours = hours % 24;
  return '${days}d ${restHours}h';
}
