/// Premium audio engine (Phase 1) — public surface.
///
/// The playback experience layer: gapless transitions, crossfade, ReplayGain,
/// loudness normalization and the advanced queue engine, composed in
/// [AudioEngine](audio_engine.dart) and wired to the player by
/// `providers/audio_engine_provider.dart`.
library;

export 'audio_engine.dart';
export 'crossfade_manager.dart';
export 'gapless_manager.dart';
export 'normalization_manager.dart';
export 'queue_manager.dart';
export 'replaygain_processor.dart';
