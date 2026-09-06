/// ReplayGain processor — track/album/smart gain selection with manual
/// overrides (premium audio engine, Phase 1).
///
/// Sits on top of the existing pure math in `engine/replay_gain.dart` and the
/// target-loudness policy in `engine/advanced_audio.dart`:
///
///   * **Track gain** — per-track normalization (the classic default).
///   * **Album gain** — one gain for the whole album so relative dynamics
///     inside an album survive.
///   * **Smart gain detection** — album gain while an album plays start to
///     finish, track gain in shuffle/mixed contexts.
///   * **Manual override** — a user-supplied gain per track or album that
///     replaces the tag gain (clamped, still clipping-protected).
///   * **Loudness normalization** — converts the ReplayGain reference gain to
///     a user-chosen target LUFS via [LoudnessNormalizationSettings].
///
/// Pure Dart: no Flutter, no I/O, no platform channels. The audio service
/// feeds it the tag set probed for the current track and applies the returned
/// volume multiplier.
library;

import 'package:spotiflac_android/engine/advanced_audio.dart';
import 'package:spotiflac_android/engine/replay_gain.dart';

/// How the player selects which gain to apply.
enum ReplayGainMode {
  /// No normalization: the files play at their mastered level.
  off('Off'),

  /// Per-track gain (falls back to album gain when the track tag is absent).
  track('Track'),

  /// Album gain (falls back to track gain when the album tag is absent).
  album('Album'),

  /// Album gain while an album plays in order, track gain otherwise.
  smart('Smart');

  const ReplayGainMode(this.label);

  final String label;

  static ReplayGainMode fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final mode in ReplayGainMode.values) {
      if (mode.name == text) return mode;
    }
    return ReplayGainMode.off;
  }
}

/// The loudness tags resolved for one track (already parsed from
/// ReplayGain/R128 tags or carried by a `StreamDescriptor`).
class GainTagSet {
  static const GainTagSet empty = GainTagSet();

  final double? trackGainDb;
  final double? albumGainDb;
  final double? trackPeak;
  final double? albumPeak;

  const GainTagSet({
    this.trackGainDb,
    this.albumGainDb,
    this.trackPeak,
    this.albumPeak,
  });

  bool get hasAnyGain => trackGainDb != null || albumGainDb != null;

  /// Parses one tag value defensively (num or numeric string; rejects
  /// NaN/infinity). Shared with the manual-override parser.
  static double? parseFinite(Object? raw) {
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }
}

/// Everything the processor needs to know about the *context* of the track
/// that is about to play.
class GainContext {
  /// Stable identity of the track (media id); the manual-override key.
  final String trackId;

  /// Stable identity of the album (album artist + album name), used for
  /// album-scoped manual overrides. May be empty when unknown.
  final String albumKey;

  /// True when the previous and next queue items belong to the same album —
  /// the signal smart mode uses to prefer album gain.
  final bool isAlbumContext;

  /// True when the queue is shuffled: album sequencing is broken by design.
  final bool shuffle;

  const GainContext({
    required this.trackId,
    this.albumKey = '',
    this.isAlbumContext = false,
    this.shuffle = false,
  });
}

/// Where the applied gain came from — recorded for the now-playing debug
/// surface and for tests.
enum GainSource { none, manualTrack, manualAlbum, trackTag, albumTag }

/// The result of one gain resolution.
class ResolvedGain {
  static const ResolvedGain unity = ResolvedGain(
    volume: 1.0,
    gainDb: null,
    source: GainSource.none,
  );

  /// Final volume multiplier (0.0 .. 1.0) for the platform player.
  final double volume;

  /// The gain actually applied in dB (before the 0..1 clamp), or null when
  /// no gain was applied.
  final double? gainDb;

  final GainSource source;

  const ResolvedGain({
    required this.volume,
    required this.source,
    this.gainDb,
  });

  bool get applied => volume != 1.0 || gainDb != null;
}

/// Manual per-track / per-album gain overrides.
///
/// Keys are `track:<id>` and `album:<key>`; values are gains in dB clamped to
/// [-12, +12]. Overrides persist with the audio-engine settings and always win
/// over tags.
class ManualGainOverrides {
  static const double minDb = -12.0;
  static const double maxDb = 12.0;

  final Map<String, double> _byKey = <String, double>{};

  static String trackKey(String trackId) => 'track:$trackId';
  static String albumKey(String albumKey) => 'album:$albumKey';

  double? forTrack(String trackId) => _byKey[trackKey(trackId)];

  double? forAlbum(String album) => _byKey[albumKey(album)];

  /// First match wins: track overrides beat album overrides.
  double? lookup({required String trackId, required String albumKey}) {
    return forTrack(trackId) ?? forAlbum(albumKey);
  }

  void setTrack(String trackId, double gainDb) =>
      _byKey[trackKey(trackId)] = _clamp(gainDb);

  void setAlbum(String album, double gainDb) =>
      _byKey[albumKey(album)] = _clamp(gainDb);

  void removeTrack(String trackId) => _byKey.remove(trackKey(trackId));

  void removeAlbum(String album) => _byKey.remove(albumKey(album));

  void clear() => _byKey.clear();

  int get length => _byKey.length;

  bool get isEmpty => _byKey.isEmpty;

  static double _clamp(double gainDb) => gainDb.clamp(minDb, maxDb).toDouble();
}

/// Immutable processor configuration (persisted with the audio engine
/// settings).
class ReplayGainConfig {
  static const double minPreAmpDb = -6.0;
  static const double maxPreAmpDb = 6.0;

  final ReplayGainMode mode;

  /// Extra gain applied on top of the selected tag (or manual override).
  final double preAmpDb;

  /// Reduces the volume further when the selected gain would clip a reported
  /// peak above full scale.
  final bool preventClipping;

  /// Loudness normalization: re-targets tag gains from the ReplayGain
  /// reference (-18 LUFS) to this target. Null disables re-targeting.
  final LoudnessNormalizationSettings? loudness;

  const ReplayGainConfig({
    this.mode = ReplayGainMode.off,
    this.preAmpDb = 0.0,
    this.preventClipping = true,
    this.loudness,
  });

  bool get enabled => mode != ReplayGainMode.off;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'preamp_db': preAmpDb,
    'prevent_clipping': preventClipping,
    if (loudness != null) 'loudness': loudness!.toJson(),
  };

  static ReplayGainConfig fromJson(Map<String, Object?> json) {
    final loudnessRaw = json['loudness'];
    return ReplayGainConfig(
      mode: ReplayGainMode.fromName(json['mode']),
      preAmpDb: (GainTagSet.parseFinite(json['preamp_db']) ?? 0.0).clamp(
        minPreAmpDb,
        maxPreAmpDb,
      ),
      preventClipping: json['prevent_clipping'] != false,
      loudness: loudnessRaw is Map
          ? LoudnessNormalizationSettings.fromJson(
              Map<String, Object?>.from(loudnessRaw),
            )
          : null,
    );
  }
}

/// The processor.
class ReplayGainProcessor {
  ReplayGainConfig _config = const ReplayGainConfig();
  final ManualGainOverrides overrides = ManualGainOverrides();

  ReplayGainConfig get config => _config;

  /// Installs a new configuration. Returns true when the effective behaviour
  /// changed (callers use this to decide whether to re-apply volume).
  bool configure(ReplayGainConfig config) {
    final changed = _config.mode != config.mode ||
        _config.preAmpDb != config.preAmpDb ||
        _config.preventClipping != config.preventClipping ||
        _config.loudness?.enabled != config.loudness?.enabled ||
        _config.loudness?.targetLufs != config.loudness?.targetLufs ||
        _config.loudness?.preampDbMax != config.loudness?.preampDbMax;
    _config = config;
    return changed;
  }

  /// Resolves the volume multiplier for one track.
  ///
  /// Returns [ResolvedGain.unity] when normalization is off or no gain
  /// source exists — the platform volume control can only attenuate, so a
  /// positive (amplifying) gain clamps at 1.0 by contract.
  ResolvedGain resolve({
    required GainContext context,
    GainTagSet tags = GainTagSet.empty,
  }) {
    final config = _config;
    if (!config.enabled) return ResolvedGain.unity;

    // 1) Manual overrides always win (still clipping-protected below).
    final manualDb = overrides.lookup(
      trackId: context.trackId,
      albumKey: context.albumKey,
    );
    if (manualDb != null) {
      final manualSource = overrides.forTrack(context.trackId) != null
          ? GainSource.manualTrack
          : GainSource.manualAlbum;
      return _apply(manualDb, manualSource, tags, config);
    }

    // 2) Mode-based selection.
    double? gainDb;
    var source = GainSource.none;
    switch (config.mode) {
      case ReplayGainMode.off:
        return ResolvedGain.unity;
      case ReplayGainMode.track:
        gainDb = tags.trackGainDb ?? tags.albumGainDb;
        source = tags.trackGainDb != null
            ? GainSource.trackTag
            : GainSource.albumTag;
        break;
      case ReplayGainMode.album:
        gainDb = tags.albumGainDb ?? tags.trackGainDb;
        source = tags.albumGainDb != null
            ? GainSource.albumTag
            : GainSource.trackTag;
        break;
      case ReplayGainMode.smart:
        final preferAlbum = context.isAlbumContext && !context.shuffle;
        gainDb = preferAlbum
            ? (tags.albumGainDb ?? tags.trackGainDb)
            : (tags.trackGainDb ?? tags.albumGainDb);
        source = preferAlbum ? GainSource.albumTag : GainSource.trackTag;
        break;
    }
    if (gainDb == null) return ResolvedGain.unity;
    return _apply(gainDb, source, tags, config);
  }

  /// Applies pre-amp, loudness re-targeting, and clipping prevention to a raw
  /// selected gain.
  ResolvedGain _apply(
    double gainDb,
    GainSource source,
    GainTagSet tags,
    ReplayGainConfig config,
  ) {
    var effectiveDb = gainDb;

    // Loudness normalization re-targets the ReplayGain reference to the
    // configured target loudness (streaming services mix down to -14 LUFS,
    // broadcast uses -23; the honest default stays the RG reference).
    final loudness = config.loudness;
    if (loudness != null && loudness.enabled) {
      effectiveDb = loudness.gainDbFor(effectiveDb);
    }

    effectiveDb += config.preAmpDb;

    var volume = ReplayGain.dbToLinear(effectiveDb).clamp(0.0, 1.0);
    if (config.preventClipping && volume >= 1.0) {
      final peak = tags.trackPeak ?? tags.albumPeak;
      if (peak != null && peak > 1.0) {
        volume = (1.0 / peak).clamp(0.0, 1.0);
      }
    }
    return ResolvedGain(
      volume: volume,
      gainDb: effectiveDb,
      source: source,
    );
  }

  /// Smart-gain detection helper: which gain *would* smart mode pick for
  /// [context]. Used by the settings UI to explain the current behaviour and
  /// by tests to pin the detection rules.
  static bool prefersAlbumGain(GainContext context) =>
      context.isAlbumContext && !context.shuffle;
}
