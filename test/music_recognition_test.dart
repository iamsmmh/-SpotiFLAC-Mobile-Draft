import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/recognition/fingerprint_engine.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_models.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_provider.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_service.dart';

/// Provider stub returning a canned attempt.
class _StubProvider implements RecognitionProvider {
  _StubProvider({
    required this.providerId,
    required this.attempt,
    this.isConfigured = true,
  });

  @override
  final String providerId;

  final RecognitionAttempt attempt;

  @override
  final bool isConfigured;

  int calls = 0;

  @override
  String get displayName => providerId;

  @override
  Future<RecognitionAttempt> identify(AudioFingerprint fingerprint) async {
    calls++;
    return attempt;
  }
}

class _StubFingerprintEngine implements FingerprintEngine {
  _StubFingerprintEngine({this.throwMessage});

  final String? throwMessage;

  @override
  Future<AudioFingerprint> fingerprint(RecognitionSample sample) async {
    final message = throwMessage;
    if (message != null) throw FingerprintException(message);
    return const AudioFingerprint(
      fingerprint: 'AQAAAA',
      duration: Duration(seconds: 12),
    );
  }
}

class _StubRecorder implements RecognitionRecorder {
  bool cancelled = false;

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<RecognitionSample> record(Duration duration) async {
    // Points at a path that does not exist; the service deletes best-effort.
    return RecognitionSample(
      filePath: '/tmp/spotiflac-test-sample-does-not-exist.wav',
      duration: duration,
    );
  }
}

RecognitionResult _result(String id, {double confidence = 0.9}) {
  return RecognitionResult(
    resultId: id,
    title: 'Title $id',
    artist: 'Artist',
    providerId: 'stub',
    confidence: confidence,
    identifiedAt: DateTime.utc(2026),
  );
}

void main() {
  final sample = RecognitionSample(
    filePath: '/tmp/sample.wav',
    duration: const Duration(seconds: 12),
  );

  group('AcoustID response decoding', () {
    test('flattens results and recordings into ranked candidates', () {
      const body = '''
      {"status":"ok","results":[
        {"id":"acoust-1","score":0.93,"recordings":[
          {"id":"mb-1","title":"Blue Monday",
           "artists":[{"name":"New Order"}],
           "releasegroups":[{"title":"Power, Corruption & Lies"}]}]},
        {"id":"acoust-2","score":0.42,"recordings":[
          {"id":"mb-2","title":"Blue Monday (Remix)",
           "artists":[{"name":"New Order"}]}]}]}
      ''';
      final attempt = AcoustIdRecognitionProvider.parseResponse(body);

      expect(attempt.isMatch, isTrue);
      expect(attempt.results.length, 2);
      expect(attempt.best!.title, 'Blue Monday');
      expect(attempt.best!.artist, 'New Order');
      expect(attempt.best!.album, 'Power, Corruption & Lies');
      expect(attempt.best!.confidence, closeTo(0.93, 1e-9));
      expect(attempt.best!.externalIds['musicbrainz'], 'mb-1');
    });

    test('sorts candidates by descending confidence', () {
      const body = '''
      {"status":"ok","results":[
        {"id":"a","score":0.3,"recordings":[{"id":"1","title":"Low"}]},
        {"id":"b","score":0.8,"recordings":[{"id":"2","title":"High"}]}]}
      ''';
      final attempt = AcoustIdRecognitionProvider.parseResponse(body);
      expect(attempt.results.map((r) => r.title), <String>['High', 'Low']);
    });

    test('joins multi-artist credits using joinphrase', () {
      const body = '''
      {"status":"ok","results":[{"id":"a","score":1,"recordings":[
        {"id":"1","title":"Duet","artists":[
          {"name":"Alice","joinphrase":" & "},{"name":"Bob"}]}]}]}
      ''';
      final attempt = AcoustIdRecognitionProvider.parseResponse(body);
      expect(attempt.best!.artist, 'Alice & Bob');
    });

    test('an empty result set is a definitive no-match', () {
      final attempt = AcoustIdRecognitionProvider.parseResponse(
        '{"status":"ok","results":[]}',
      );
      expect(attempt.outcome, RecognitionOutcome.noMatch);
    });

    test('recordings without a title are skipped', () {
      const body = '''
      {"status":"ok","results":[{"id":"a","score":1,"recordings":[
        {"id":"1"},{"id":"2","title":"Real"}]}]}
      ''';
      final attempt = AcoustIdRecognitionProvider.parseResponse(body);
      expect(attempt.results.single.title, 'Real');
    });

    test('an API error is unavailable, not a no-match', () {
      const body = '''
      {"status":"error","error":{"message":"invalid API key"}}
      ''';
      final attempt = AcoustIdRecognitionProvider.parseResponse(body);
      expect(attempt.outcome, RecognitionOutcome.unavailable);
      expect(attempt.message, 'invalid API key');
    });

    test('malformed JSON is unavailable', () {
      final attempt = AcoustIdRecognitionProvider.parseResponse('nope');
      expect(attempt.outcome, RecognitionOutcome.unavailable);
    });
  });

  group('AcoustID configuration gate', () {
    test('an unconfigured provider reports unavailable without a request', () async {
      final provider = AcoustIdRecognitionProvider(apiKey: '  ');
      expect(provider.isConfigured, isFalse);

      final attempt = await provider.identify(
        const AudioFingerprint(
          fingerprint: 'AQAAAA',
          duration: Duration(seconds: 12),
        ),
      );
      expect(attempt.outcome, RecognitionOutcome.unavailable);
    });

    test('an empty fingerprint is rejected before the network', () async {
      final provider = AcoustIdRecognitionProvider(apiKey: 'key');
      final attempt = await provider.identify(
        const AudioFingerprint(fingerprint: '', duration: Duration.zero),
      );
      expect(attempt.outcome, RecognitionOutcome.fingerprintFailed);
    });
  });

  group('MusicRecognitionService provider chaining', () {
    test('returns the first provider that matches', () async {
      final first = _StubProvider(
        providerId: 'a',
        attempt: RecognitionAttempt.noMatch,
      );
      final second = _StubProvider(
        providerId: 'b',
        attempt: RecognitionAttempt(
          outcome: RecognitionOutcome.matched,
          results: <RecognitionResult>[_result('hit')],
        ),
      );
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[first, second],
        fingerprintEngine: _StubFingerprintEngine(),
        history: _NoopHistory(),
      );

      final attempt = await service.identifyFromSample(sample);

      expect(attempt.isMatch, isTrue);
      expect(attempt.best!.resultId, 'hit');
      expect(first.calls, 1);
      expect(second.calls, 1);
    });

    test('stops as soon as a provider matches', () async {
      final first = _StubProvider(
        providerId: 'a',
        attempt: RecognitionAttempt(
          outcome: RecognitionOutcome.matched,
          results: <RecognitionResult>[_result('hit')],
        ),
      );
      final second = _StubProvider(
        providerId: 'b',
        attempt: RecognitionAttempt.noMatch,
      );
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[first, second],
        fingerprintEngine: _StubFingerprintEngine(),
        history: _NoopHistory(),
      );

      await service.identifyFromSample(sample);
      expect(second.calls, 0);
    });

    test('unconfigured providers are skipped entirely', () async {
      final skipped = _StubProvider(
        providerId: 'a',
        isConfigured: false,
        attempt: RecognitionAttempt(
          outcome: RecognitionOutcome.matched,
          results: <RecognitionResult>[_result('never')],
        ),
      );
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[skipped],
        fingerprintEngine: _StubFingerprintEngine(),
        history: _NoopHistory(),
      );

      final attempt = await service.identifyFromSample(sample);

      expect(skipped.calls, 0);
      expect(attempt.isMatch, isFalse);
      expect(attempt.outcome, RecognitionOutcome.unavailable);
    });

    test('a definitive no-match outranks a provider outage in the summary',
        () async {
      final unavailable = _StubProvider(
        providerId: 'a',
        attempt: const RecognitionAttempt(
          outcome: RecognitionOutcome.unavailable,
        ),
      );
      final noMatch = _StubProvider(
        providerId: 'b',
        attempt: RecognitionAttempt.noMatch,
      );
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[unavailable, noMatch],
        fingerprintEngine: _StubFingerprintEngine(),
        history: _NoopHistory(),
      );

      final attempt = await service.identifyFromSample(sample);
      expect(attempt.outcome, RecognitionOutcome.noMatch);
    });

    test('a fingerprint failure short-circuits before any provider', () async {
      final provider = _StubProvider(
        providerId: 'a',
        attempt: RecognitionAttempt.noMatch,
      );
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[provider],
        fingerprintEngine: _StubFingerprintEngine(throwMessage: 'no codec'),
        history: _NoopHistory(),
      );

      final attempt = await service.identifyFromSample(sample);

      expect(attempt.outcome, RecognitionOutcome.fingerprintFailed);
      expect(attempt.message, 'no codec');
      expect(provider.calls, 0);
    });

    test('microphone capture refuses to run with no configured provider',
        () async {
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[
          _StubProvider(
            providerId: 'a',
            isConfigured: false,
            attempt: RecognitionAttempt.noMatch,
          ),
        ],
        fingerprintEngine: _StubFingerprintEngine(),
        history: _NoopHistory(),
      );

      expect(service.hasConfiguredProvider, isFalse);
      final attempt = await service.identifyFromMicrophone();
      expect(attempt.outcome, RecognitionOutcome.unavailable);
    });

    test('a matched result is written to history', () async {
      final history = _NoopHistory();
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[
          _StubProvider(
            providerId: 'a',
            attempt: RecognitionAttempt(
              outcome: RecognitionOutcome.matched,
              results: <RecognitionResult>[_result('saved')],
            ),
          ),
        ],
        fingerprintEngine: _StubFingerprintEngine(),
        history: history,
      );

      await service.identifyFromSample(sample);
      expect(history.saved.single.resultId, 'saved');
    });

    test('history writing can be suppressed', () async {
      final history = _NoopHistory();
      final service = MusicRecognitionService(
        recorder: _StubRecorder(),
        providers: <RecognitionProvider>[
          _StubProvider(
            providerId: 'a',
            attempt: RecognitionAttempt(
              outcome: RecognitionOutcome.matched,
              results: <RecognitionResult>[_result('x')],
            ),
          ),
        ],
        fingerprintEngine: _StubFingerprintEngine(),
        history: history,
      );

      await service.identifyFromSample(sample, saveToHistory: false);
      expect(history.saved, isEmpty);
    });
  });

  group('RecognitionResult', () {
    test('round-trips through its history row', () {
      final original = RecognitionResult(
        resultId: 'acoustid:mb-1',
        title: 'Blue Monday',
        artist: 'New Order',
        album: 'Substance',
        providerId: 'acoustid',
        confidence: 0.87,
        artworkUrl: 'https://a/art.jpg',
        isrc: 'GBAAA0000001',
        externalIds: const <String, String>{'musicbrainz': 'mb-1'},
        identifiedAt: DateTime.utc(2026, 3, 4, 5),
      );

      final restored = RecognitionResult.fromRow(original.toRow());

      expect(restored.resultId, original.resultId);
      expect(restored.title, original.title);
      expect(restored.confidence, closeTo(0.87, 1e-9));
      expect(restored.artworkUrl, 'https://a/art.jpg');
      expect(restored.isrc, 'GBAAA0000001');
      expect(restored.externalIds['musicbrainz'], 'mb-1');
      expect(restored.identifiedAt, original.identifiedAt);
    });

    test('a corrupt payload blob does not break history rendering', () {
      final restored = RecognitionResult.fromRow(<String, Object?>{
        'result_id': 'r',
        'title': 'T',
        'payload_json': 'not-json',
        'identified_at': '2026-01-01T00:00:00Z',
      });
      expect(restored.title, 'T');
      expect(restored.externalIds, isEmpty);
      expect(restored.isrc, isNull);
    });

    test('builds a search query for handing off to the catalogue', () {
      expect(_result('x').searchQuery, 'Artist Title x');
      expect(
        RecognitionResult(
          resultId: 'x',
          title: 'Solo',
          identifiedAt: DateTime.utc(2026),
        ).searchQuery,
        'Solo',
      );
    });

    test('display label degrades gracefully with no artist', () {
      expect(
        RecognitionResult(
          resultId: 'x',
          title: 'Solo',
          identifiedAt: DateTime.utc(2026),
        ).displayLabel,
        'Solo',
      );
      expect(_result('x').displayLabel, 'Artist \u2013 Title x');
    });
  });
}

/// In-memory history so service tests never touch SQLite.
class _NoopHistory implements RecognitionHistoryStore {
  final List<RecognitionResult> saved = <RecognitionResult>[];

  @override
  Future<void> save(RecognitionResult result) async => saved.add(result);

  @override
  Future<List<RecognitionResult>> recent({int limit = 100}) async => saved;

  @override
  Future<void> remove(String resultId) async {
    saved.removeWhere((result) => result.resultId == resultId);
  }

  @override
  Future<void> clear() async => saved.clear();

  @override
  Future<int> count() async => saved.length;
}
