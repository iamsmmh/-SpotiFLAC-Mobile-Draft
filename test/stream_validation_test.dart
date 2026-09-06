import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';

/// HTTP client that answers a ranged request from a scripted response.
class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.statusCode, this.headers, {this.delay = Duration.zero});

  final int statusCode;
  final Map<String, String> headers;
  final Duration delay;

  http.BaseRequest? lastRequest;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    lastRequest = request;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('x')),
      statusCode,
      headers: headers,
      request: request,
    );
  }
}

ResolvedStream _stream(String uri) => ResolvedStream(
  uri: Uri.parse(uri),
  provider: StreamProviderId.youtube,
  qualityLabel: 'Opus 160kbps',
  matchedTitle: 'Song',
);

void main() {
  group('HttpStreamValidator', () {
    test('accepts a ranged audio response and reports latency + size',
        () async {
      final client = _FakeHttpClient(206, <String, String>{
        'content-type': 'audio/webm',
        'content-length': '1234567',
      });
      final validator = HttpStreamValidator(client: client);
      final result = await validator.validate(_stream('https://cdn/a'));

      expect(result.ok, isTrue);
      expect(result.statusCode, 206);
      expect(result.contentType, 'audio/webm');
      expect(result.contentLengthBytes, 1234567);
      expect(result.latencyMs, isNotNull);
      expect(result.error, isNull);
      // One byte is enough to prove the URL is alive.
      expect(client.lastRequest!.headers['Range'], 'bytes=0-0');
      expect(client.calls, 1);
    });

    test('rejects a non-2xx status', () async {
      final validator = HttpStreamValidator(
        client: _FakeHttpClient(403, const <String, String>{}),
      );
      final result = await validator.validate(_stream('https://cdn/expired'));
      expect(result.ok, isFalse);
      expect(result.error, 'HTTP 403');
    });

    test('rejects an HTML error page served with 200', () async {
      final validator = HttpStreamValidator(
        client: _FakeHttpClient(200, <String, String>{
          'content-type': 'text/html; charset=utf-8',
        }),
      );
      final result = await validator.validate(_stream('https://cdn/page'));
      expect(result.ok, isFalse);
      expect(result.error, contains('text/html'));
    });

    test('rejects a JSON error body served with 200', () async {
      final validator = HttpStreamValidator(
        client: _FakeHttpClient(200, <String, String>{
          'content-type': 'application/json',
        }),
      );
      final result = await validator.validate(_stream('https://cdn/api'));
      expect(result.ok, isFalse);
    });

    test('an unknown content type is not treated as failure', () async {
      final validator = HttpStreamValidator(
        client: _FakeHttpClient(200, const <String, String>{}),
      );
      expect((await validator.validate(_stream('https://cdn/a'))).ok, isTrue);
    });

    test('times out instead of hanging the resolution chain', () async {
      final validator = HttpStreamValidator(
        client: _FakeHttpClient(200, const <String, String>{},
            delay: const Duration(seconds: 5)),
        timeout: const Duration(milliseconds: 30),
      );
      final result = await validator.validate(_stream('https://cdn/slow'));
      expect(result.ok, isFalse);
      expect(result.error, contains('Timed out'));
    });

    test('rejects non-http sources without touching the network', () async {
      final client = _FakeHttpClient(200, const <String, String>{});
      final validator = HttpStreamValidator(client: client);
      final result = await validator.validate(_stream('file:///music/a.flac'));
      expect(result.ok, isFalse);
      expect(result.error, 'Unsupported URI scheme');
      expect(client.calls, 0);
    });
  });

  group('StreamValidationResult', () {
    test('flags plausible audio content types', () {
      expect(
        StreamValidationResult.isPlausibleAudioContentType('audio/webm'),
        isTrue,
      );
      expect(
        StreamValidationResult.isPlausibleAudioContentType('audio/flac'),
        isTrue,
      );
      expect(
        StreamValidationResult.isPlausibleAudioContentType(null),
        isTrue,
      );
      expect(
        StreamValidationResult.isPlausibleAudioContentType('text/html'),
        isFalse,
      );
      expect(
        StreamValidationResult.isPlausibleAudioContentType(
          'application/json; charset=utf-8',
        ),
        isFalse,
      );
    });
  });
}
