import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/advanced_audio.dart';
import 'package:spotiflac_android/engine/replay_gain.dart';

void main() {
  const tags = GainTagSet(
    trackGainDb: -6.0,
    albumGainDb: -8.0,
    trackPeak: 1.2,
    albumPeak: 1.2,
  );

  GainContext ctx({
    String trackId = 't1',
    String albumKey = 'a1',
    bool album = false,
    bool shuffle = false,
  }) =>
      GainContext(
        trackId: trackId,
        albumKey: albumKey,
        isAlbumContext: album,
        shuffle: shuffle,
      );

  group('ReplayGainMode', () {
    test('parses names leniently', () {
      expect(ReplayGainMode.fromName('album'), ReplayGainMode.album);
      expect(ReplayGainMode.fromName('SMART'), ReplayGainMode.smart);
      expect(ReplayGainMode.fromName('nonsense'), ReplayGainMode.off);
      expect(ReplayGainMode.fromName(null), ReplayGainMode.off);
    });
  });

  group('ReplayGainProcessor', () {
    test('off mode stays at unity volume', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.off));
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.volume, 1.0);
      expect(resolved.applied, isFalse);
    });

    test('track mode prefers the track gain', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-6.0), 1e-9));
      expect(resolved.source, GainSource.trackTag);
    });

    test('track mode falls back to the album gain', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final resolved = processor.resolve(
        context: ctx(),
        tags: const GainTagSet(albumGainDb: -8.0),
      );
      expect(resolved.source, GainSource.albumTag);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-8.0), 1e-9));
    });

    test('album mode prefers the album gain', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.album));
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.source, GainSource.albumTag);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-8.0), 1e-9));
    });

    test('smart mode uses album gain in album context and track gain otherwise',
        () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.smart));
      final inAlbum = processor.resolve(
        context: ctx(album: true),
        tags: tags,
      );
      expect(inAlbum.volume, closeTo(ReplayGain.dbToLinear(-8.0), 1e-9));
      final shuffled = processor.resolve(
        context: ctx(album: true, shuffle: true),
        tags: tags,
      );
      expect(shuffled.volume, closeTo(ReplayGain.dbToLinear(-6.0), 1e-9));
    });

    test('smart detection helper ignores album context while shuffling', () {
      expect(
        ReplayGainProcessor.prefersAlbumGain(ctx(album: true)),
        isTrue,
      );
      expect(
        ReplayGainProcessor.prefersAlbumGain(ctx(album: true, shuffle: true)),
        isFalse,
      );
    });

    test('positive gains clamp at 1.0 (volume can only attenuate)', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final resolved = processor.resolve(
        context: ctx(),
        tags: const GainTagSet(trackGainDb: 4.0),
      );
      expect(resolved.volume, 1.0);
    });

    test('prevent clipping reduces gain when the peak exceeds full scale', () {
      final processor = ReplayGainProcessor()
        ..configure(
          const ReplayGainConfig(
            mode: ReplayGainMode.track,
            preventClipping: true,
          ),
        );
      final resolved = processor.resolve(
        context: ctx(),
        tags: const GainTagSet(trackGainDb: 4.0, trackPeak: 2.0),
      );
      expect(resolved.volume, closeTo(0.5, 1e-9));
    });

    test('manual track overrides beat tags and album overrides', () {
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      processor.overrides.setTrack('t1', -3.0);
      processor.overrides.setAlbum('a1', -10.0);
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.source, GainSource.manualTrack);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-3.0), 1e-9));

      processor.overrides.removeTrack('t1');
      final albumOverride = processor.resolve(context: ctx(), tags: tags);
      expect(albumOverride.source, GainSource.manualAlbum);
      expect(albumOverride.volume, closeTo(ReplayGain.dbToLinear(-10.0), 1e-9));
    });

    test('pre-amp shifts the selected gain', () {
      final processor = ReplayGainProcessor()
        ..configure(
          const ReplayGainConfig(mode: ReplayGainMode.track, preAmpDb: -2.0),
        );
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-8.0), 1e-9));
    });

    test('loudness re-targeting maps the ReplayGain reference to the target',
        () {
      final processor = ReplayGainProcessor()
        ..configure(
          ReplayGainConfig(
            mode: ReplayGainMode.track,
            loudness: const LoudnessNormalizationSettings(
              enabled: true,
              targetLufs: -14.0,
            ),
          ),
        );
      // Track gain -6 dB vs -18 reference → master is at -24 LUFS. At a -14
      // target the required gain is -6 + 4 = -2 dB.
      final resolved = processor.resolve(context: ctx(), tags: tags);
      expect(resolved.volume, closeTo(ReplayGain.dbToLinear(-2.0), 1e-9));
    });

    test('configure reports whether the audible behaviour changed', () {
      final processor = ReplayGainProcessor();
      expect(
        processor.configure(const ReplayGainConfig(mode: ReplayGainMode.track)),
        isTrue,
      );
      expect(
        processor.configure(const ReplayGainConfig(mode: ReplayGainMode.track)),
        isFalse,
      );
      expect(
        processor.configure(
          const ReplayGainConfig(mode: ReplayGainMode.track, preAmpDb: -1.0),
        ),
        isTrue,
      );
    });
  });

  group('ManualGainOverrides', () {
    test('clamps to ±12 dB on write', () {
      final overrides = ManualGainOverrides()
        ..setTrack('t1', -30.0)
        ..setAlbum('a1', 30.0);
      expect(overrides.forTrack('t1'), -12.0);
      expect(overrides.forAlbum('a1'), 12.0);
      expect(overrides.length, 2);
    });

    test('track override wins over album override on lookup', () {
      final overrides = ManualGainOverrides()
        ..setTrack('t1', -1.0)
        ..setAlbum('a1', -2.0);
      expect(
        overrides.lookup(trackId: 't1', albumKey: 'a1'),
        -1.0,
      );
      overrides.removeTrack('t1');
      expect(
        overrides.lookup(trackId: 't1', albumKey: 'a1'),
        -2.0,
      );
    });

    test('parseFinite rejects non-finite values', () {
      expect(GainTagSet.parseFinite(double.infinity), isNull);
      expect(GainTagSet.parseFinite(double.nan), isNull);
      expect(GainTagSet.parseFinite('x'), isNull);
      expect(GainTagSet.parseFinite(-3.5), -3.5);
      expect(GainTagSet.parseFinite('2.5'), 2.5);
    });

    test('remove/clear manage the override table', () {
      final overrides = ManualGainOverrides()
        ..setTrack('t1', -1.0)
        ..setAlbum('a1', -2.0);
      overrides.removeTrack('t1');
      expect(overrides.forTrack('t1'), isNull);
      expect(overrides.isEmpty, isFalse);
      overrides.clear();
      expect(overrides.isEmpty, isTrue);
      expect(overrides.length, 0);
    });
  });

  group('ReplayGainConfig', () {
    test('defaults and the enabled flag', () {
      const off = ReplayGainConfig();
      expect(off.mode, ReplayGainMode.off);
      expect(off.enabled, isFalse);
      const on = ReplayGainConfig(mode: ReplayGainMode.track);
      expect(on.enabled, isTrue);
      expect(on.preventClipping, isTrue);
    });
  });
}
