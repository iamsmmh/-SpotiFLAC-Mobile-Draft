import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/audio_effects.dart';
import 'package:spotiflac_android/services/audio/audio_quality_inspector.dart';
import 'package:spotiflac_android/services/audio/ios_avaudio_engine_eq.dart';
import 'package:spotiflac_android/services/history/history_analytics_service.dart';
import 'package:spotiflac_android/services/lan/lan_player_security.dart';
import 'package:spotiflac_android/services/observability/observability.dart';
import 'package:spotiflac_android/services/performance/performance.dart';

void main() {
  group('HistoryAnalyticsService', () {
    test('counts plays, duration and completion', () {
      const service = HistoryAnalyticsService();
      final events = <PlayEvent>[
        PlayEvent(
          trackKey: 't1',
          title: 'One',
          artist: 'Ada',
          album: 'A',
          durationMs: 100000,
          playedMs: 95000,
          startedAt: DateTime.utc(2026, 9, 1, 10),
          endedAt: DateTime.utc(2026, 9, 1, 10, 2),
        ),
        PlayEvent(
          trackKey: 't2',
          title: 'Two',
          artist: 'Ada',
          album: 'A',
          durationMs: 100000,
          playedMs: 10000,
          skipped: true,
          startedAt: DateTime.utc(2026, 9, 2, 10),
          endedAt: DateTime.utc(2026, 9, 2, 10, 1),
        ),
      ];
      final snapshot = service.summarize(
        events,
        rangeStart: DateTime.utc(2026, 9, 1),
        rangeEnd: DateTime.utc(2026, 9, 7),
      );
      expect(snapshot.playCount, 2);
      expect(snapshot.skipCount, 1);
      expect(snapshot.completedCount, 1);
      expect(snapshot.uniqueTracks, 2);
      expect(snapshot.recap.milestones, isNotEmpty);
    });
  });

  group('AudioQualityInspector', () {
    const inspector = AudioQualityInspector();

    test('maps hi-res / lossless / lossy onto badges', () {
      expect(
        inspector
            .inspect(
              const AudioCharacteristics(
                codec: 'FLAC',
                bitDepth: 24,
                sampleRateHz: 96000,
                lossless: true,
              ),
            )
            .badge,
        AudioQualityBadge.hires,
      );
      expect(
        inspector
            .inspect(
              const AudioCharacteristics(
                codec: 'FLAC',
                bitDepth: 16,
                sampleRateHz: 44100,
                lossless: true,
              ),
            )
            .badge,
        AudioQualityBadge.lossless,
      );
      expect(
        inspector
            .inspect(
              const AudioCharacteristics(codec: 'MP3', bitrateKbps: 320),
            )
            .badge,
        AudioQualityBadge.high,
      );
    });
  });

  group('LanPlayerSecurity', () {
    const security = LanPlayerSecurity();

    test('short PINs disable the gate; tokens authorize', () {
      expect(security.normalizePin('12'), isNull);
      expect(security.authorize(pin: '12'), isTrue);
      const pin = '2468';
      final token = security.tokenForPin(pin);
      expect(token, hasLength(64));
      expect(
        security.authorize(pin: pin, headerPin: pin),
        isTrue,
      );
      expect(
        security.authorize(pin: pin, bearerToken: token),
        isTrue,
      );
      expect(security.authorize(pin: pin), isFalse);
      expect(security.isReadOnlyMethod('GET'), isTrue);
      expect(security.isReadOnlyMethod('POST'), isFalse);
      expect(security.startConfig(root: '/music', pin: pin)['pin'], pin);
    });
  });

  group('IosAvAudioEngineEqPolicy', () {
    test('projects toPlatformMap onto parametric bands', () {
      const policy = IosAvAudioEngineEqPolicy();
      final settings = AudioEffectsSettings(
        enabled: true,
        bandGainsDb: const <double>[6, 0, 0, 0, 0, 0, 0, 0, 0, 4],
        bassBoost: 0.5,
      );
      final payload = policy.fromSettings(settings);
      expect(payload.enabled, isTrue);
      expect(payload.bands, hasLength(10));
      expect(payload.bands.first.frequencyHz, equalizerBandFrequencies.first);
      expect(payload.bassDb, closeTo(4, 0.01));
      expect(payload.toJson()['bands'], isA<List<Map<String, Object?>>>());
    });
  });

  group('Performance budgets', () {
    test('search / startup / frame limits', () {
      expect(
        PerformanceBudget.search.within(const Duration(milliseconds: 149)),
        isTrue,
      );
      expect(
        PerformanceBudget.search.within(const Duration(milliseconds: 151)),
        isFalse,
      );
      expect(
        PerformanceBudget.startup.within(const Duration(seconds: 2)),
        isTrue,
      );
      expect(
        PerformanceBudget.frame.limit.inMicroseconds,
        16667,
      );
      const set = LibraryWorkingSet();
      expect(set.clampTrackCount(200000), 100000);
      expect(set.clampPlaylistEntries(50), 50);
    });

    test('paged library windows a 100k catalog', () {
      const pager = PagedLibrary<int>(pageSize: 200);
      final all = List<int>.generate(1000, (i) => i);
      final page = pager.page(all, offset: 400);
      expect(page.items.first, 400);
      expect(page.items, hasLength(200));
      expect(page.hasMore, isTrue);
    });

    test('isolate fallback runs inline', () async {
      const compute = IsolateCompute(useIsolate: false);
      final result = await compute.run((int n) => n * 2, 21);
      expect(result, 42);
    });
  });

  group('SecretRedactor + ObservabilitySurface', () {
    test('redacts tokens and pins', () {
      const redactor = SecretRedactor();
      final out = redactor.redactMap(<String, Object?>{
        'token': 'secret-value',
        'pin': '2468',
        'track': 'Nightcall',
        'nested': <String, Object?>{'authorization': 'Bearer abc'},
      });
      expect(out['token'], '[redacted]');
      expect(out['pin'], '[redacted]');
      expect(out['track'], 'Nightcall');
      final nested = out['nested']! as Map<String, Object?>;
      expect(nested['authorization'], '[redacted]');
      expect(ObservabilitySurface.sync.name, 'sync');
    });
  });
}
