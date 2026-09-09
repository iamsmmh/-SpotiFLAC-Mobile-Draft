/// Unified hybrid playback layer: local, cache, and streaming playback
/// through one decision engine ([PlaybackManager]) and one shared player.
///
/// Routing policy is the existing pure [PlaybackSourceLadder] (local file →
/// verified cache → provider stream); rendering is the single audio_service
/// handler behind [MusicPlayerPlaybackBackend]. Queueing, lyrics, ReplayGain,
/// and session persistence stay in their existing owners — this layer adds
/// no parallel pipelines.
library;

export 'cache_playback_service.dart';
export 'local_playback_service.dart';
export 'playback_manager.dart';
export 'playback_source.dart';
export 'streaming_playback_service.dart';
