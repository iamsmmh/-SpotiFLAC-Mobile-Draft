/// Hybrid playback runtime (Feature 3): instant stream → silent download
/// → verified local swap.
///
/// Composes three existing systems — the streaming engine's play path
/// (`streamingEngineControllerProvider`), the stream cache
/// (`StreamingCacheManager`) and the audio player's
/// `replaceCurrentAndPlay` hot-swap — so no new playback pipeline exists.
/// The decision logic is the pure [HybridPlaybackPlanner].
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/core/streaming/hybrid_playback.dart';
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/core/streaming/stream_resolver.dart';
import 'package:spotimusic/core/streaming/stream_session.dart';
import 'package:spotimusic/ecosystem/cache/cache_models.dart';
import 'package:spotimusic/ecosystem/cache/streaming_cache_manager.dart';
import 'package:spotimusic/engine/streaming_engine.dart';
import 'package:spotimusic/engine/track_identity.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/providers/engine_settings_provider.dart';
import 'package:spotimusic/providers/music_player_provider.dart';
import 'package:spotimusic/providers/playback_provider.dart';
import 'package:spotimusic/providers/streaming_cache_providers.dart';
import 'package:spotimusic/providers/streaming_engine_provider.dart';
import 'package:spotimusic/services/music_player_service.dart';
import 'package:spotimusic/utils/logger.dart';

final _log = AppLogger('HybridPlayback');

/// Projects an engine [StreamDescriptor] onto the Feature-1 [StreamSource]
/// currency (used for session bookkeeping only).
StreamSource streamSourceOfDescriptor(StreamDescriptor descriptor) =>
    StreamSource(
      url: descriptor.uri,
      format: descriptor.characteristics.codec ?? '',
      bitrate: descriptor.characteristics.bitrateKbps ?? 0,
      protocol: StreamProtocolDetector.detect(descriptor.uri),
      providerId: descriptor.providerId,
      cachePermitted: descriptor.cachePermitted,
    );

/// Outcome surfaced to callers/UI.
class HybridPlaybackOutcome {
  const HybridPlaybackOutcome({
    required this.plan,
    required this.started,
    this.cacheEntry,
    this.message,
  });

  final HybridPlaybackPlan plan;
  final bool started;
  final CacheEntry? cacheEntry;
  final String? message;
}

/// The runtime manager. `playTrack` is the Feature-3 entry point.
class HybridPlaybackManager {
  HybridPlaybackManager({required this.ref});

  final Ref ref;

  /// Active hybrid sessions by canonical track key (diagnostics + swap).
  final Map<String, StreamSession> sessions = <String, StreamSession>{};

  String trackKeyOf(Track track) =>
      CanonicalTrackKey.fromInput(TrackIdentityInput.fromTrack(track)).stableId;

  /// Plays [track] instantly and (when the plan allows it) completes a
  /// verified local copy silently, swapping live playback to it.
  Future<HybridPlaybackOutcome> playTrack(Track track) async {
    final engine = ref.read(streamingEngineControllerProvider);
    final settings = ref.read(engineSettingsProvider);
    final key = trackKeyOf(track);
    final session = StreamSession(trackId: key);
    sessions[key] = session
      ..beginResolving();

    final localPath = await engine.downloadedPathFor(track);
    CacheHit? cacheHit;
    try {
      cacheHit = await ref
          .read(streamingCacheManagerProvider)
          .lookupPlayable(key);
    } catch (error) {
      _log.w('Cache lookup failed for ${track.name}: $error');
    }

    var streamResolved = false;
    var cachePermitted = false;
    String? streamUrl;
    if (localPath == null && cacheHit == null && !settings.offlineMode) {
      try {
        final candidates = await engine.candidatesFor(track);
        if (candidates.isNotEmpty) {
          streamResolved = true;
          final best = candidates.first;
          cachePermitted = best.cachePermitted;
          streamUrl = best.uri;
          session.markValidating(streamSourceOfDescriptor(best));
        }
      } catch (_) {
        streamResolved = false;
      }
    }

    final planner = const HybridPlaybackPlanner();
    final plan = planner.plan(
      HybridPlaybackFacts(
        hasLocalFile: localPath != null,
        hasVerifiedCache: cacheHit != null,
        streamResolved: streamResolved,
        cachePermitted: cachePermitted,
        cacheEnabled: settings.cacheStreams,
        offline: settings.offlineMode,
      ),
    );

    switch (plan.action) {
      case HybridPlaybackAction.playLocal:
        session.completeHandoff();
        await ref.read(playbackProvider.notifier).playTrackList(<Track>[track]);
        return HybridPlaybackOutcome(plan: plan, started: true);

      case HybridPlaybackAction.playCache:
        session.completeHandoff();
        await _playCacheHit(track, cacheHit!);
        return HybridPlaybackOutcome(
          plan: plan,
          started: true,
          cacheEntry: cacheHit.entry,
        );

      case HybridPlaybackAction.playStreamAndCache:
      case HybridPlaybackAction.playStream:
        // Playback through the full Smart Play ladder (health, preflight,
        // failover) — the engine owns it; the hybrid layer only adds the
        // background fetch and swap.
        final result = await engine.playTrack(track);
        if (!result.started) {
          session.fail(result.message ?? 'engine could not start playback');
          return HybridPlaybackOutcome(
            plan: plan,
            started: false,
            message: result.message,
          );
        }
        session.markPlaying();
        if (plan.backgroundFetch && streamUrl != null) {
          unawaited(_fetchAndSwap(track, session, streamUrl));
        }
        return HybridPlaybackOutcome(plan: plan, started: true);

      case HybridPlaybackAction.downloadAndPlay:
        final result = await engine.playTrack(track);
        return HybridPlaybackOutcome(
          plan: plan,
          started: result.started,
          message: result.message,
        );

      case HybridPlaybackAction.unavailable:
        session.fail(plan.reason);
        return HybridPlaybackOutcome(plan: plan, started: false, message: plan.reason);
    }
  }

  Future<void> _playCacheHit(Track track, CacheHit hit) async {
    final controller = ref.read(musicPlayerControllerProvider);
    final initialized = await controller.ensureInitialized();
    if (initialized == null) {
      // Internal player unavailable: fall back to the standard ladder.
      await ref.read(playbackProvider.notifier).playTrackList(<Track>[track]);
      return;
    }
    await controller.playSingle(
      PlayableMedia(
        id: hit.entry.cacheKey,
        source: hit.filePath,
        title: hit.entry.title,
        artist: hit.entry.artist,
        playbackMode: 'local',
        qualityLabel: hit.entry.audioFormat.label,
        sourceLabel: 'Stream cache',
      ),
    );
  }

  /// Background fetch + integrity check + live swap.
  Future<void> _fetchAndSwap(
    Track track,
    StreamSession session,
    String url,
  ) async {
    final manager = ref.read(streamingCacheManagerProvider);
    session.markCaching();
    final result = await manager.startFetch(
      CacheFetchRequest(
        trackKey: trackKeyOf(track),
        title: track.name,
        artist: track.artistName,
        url: url,
        durationMs: track.duration * 1000,
      ),
    );
    final entry = result.entry;
    if (result.status != CacheFetchStatus.completed || entry == null) {
      _log.d(
        'Hybrid cache fetch for "${track.name}" ended '
        '${result.status.name}: ${result.error ?? ''}',
      );
      return;
    }

    // Integrity gate: never swap unverified bytes into playback.
    final verified = entry.encrypted
        ? await manager.verifyEncryptedEntry(entry)
        : await manager.verifyEntry(entry);
    if (!verified) {
      _log.w('Hybrid cache verify failed for "${track.name}"; keeping stream');
      await manager.evictTrack(entry.trackKey);
      return;
    }

    // Swap only when this session is still the live one.
    final current = sessions[trackKeyOf(track)];
    if (current == null || !identical(current, session)) return;
    if (!session.phase.isStreaming) return;

    final hit = await manager.lookupPlayable(entry.trackKey);
    if (hit == null) return;
    final controller = ref.read(musicPlayerControllerProvider);
    final handler = await controller.ensureInitialized();
    if (handler == null) return;

    final position = await handler.currentPlaybackPosition();
    session.planHandoff(
      StreamHandoffPlan(
        mediaId: hit.entry.cacheKey,
        localPath: hit.filePath,
        sourceUrl: url,
        expectedSha256: entry.sha256,
        cipherEnabled: entry.encrypted,
      ),
    );
    try {
      await handler.replaceCurrentAndPlay(
        PlayableMedia(
          id: hit.entry.cacheKey,
          source: hit.filePath,
          title: entry.title,
          artist: entry.artist,
          playbackMode: 'local',
          qualityLabel: entry.audioFormat.label,
          sourceLabel: 'Stream cache',
        ),
        resumeAt: position,
      );
      session.completeHandoff();
      _log.i('Hybrid swap completed for "${track.name}" at $position');
    } catch (error) {
      _log.w('Hybrid swap failed for "${track.name}": $error (stream continues)');
    }
  }

  /// Clears session bookkeeping when playback moves on.
  void endSession(Track track) {
    sessions.remove(trackKeyOf(track))?.stop();
  }
}

final hybridPlaybackManagerProvider = Provider<HybridPlaybackManager>((ref) {
  return HybridPlaybackManager(ref: ref);
});
