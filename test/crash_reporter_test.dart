import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotimusic/core/monitoring/crash_reporter.dart';

/// Scriptable HTTP client: [responses] are served in order (a pending
/// completer stalls the request); every request is recorded.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.responses);

  final List<Object> responses; // http.Response or Future<Response> or error
  final List<http.Request> requests = <http.Request>[];
  final List<String> bodies = <String>[];

  @override
  Future<http.Response> send(http.Request request) async {
    requests.add(request);
    bodies.add(request.body);
    if (responses.isEmpty) {
      return http.Response('ok', 200);
    }
    final next = responses.removeAt(0);
    if (next is Completer<http.Response>) {
      return next.future;
    }
    if (next is http.Response) {
      return next;
    }
    throw next; // a scripted error object: the request itself fails
  }
}

http.Response _resp(int status) => http.Response('body', status);

CrashReporter _reporter({
  required http.Client client,
  List<Duration>? delays,
  DateTime Function()? now,
  int maxQueueLength = 30,
  int maxBreadcrumbs = 100,
  int rateLimitEvents = 20,
  Duration rateLimitWindow = const Duration(minutes: 10),
}) {
  final recordedDelays = delays ?? <Duration>[];
  return CrashReporter(
    httpClient: client,
    now: now ?? DateTime.now,
    delay: (d) async {
      recordedDelays.add(d);
    },
    random: Random(42),
    maxQueueLength: maxQueueLength,
    maxBreadcrumbs: maxBreadcrumbs,
    rateLimitEvents: rateLimitEvents,
    rateLimitWindow: rateLimitWindow,
  );
}

void main() {
  group('CrashReportDsn.parse', () {
    test('derives the envelope endpoint', () {
      final dsn = CrashReportDsn.parse(
        'https://abc123@sentry.example.com/42',
      );
      expect(dsn.publicKey, 'abc123');
      expect(dsn.host, 'sentry.example.com');
      expect(dsn.projectId, '42');
      expect(dsn.envelopeUrl, 'https://sentry.example.com/api/42/envelope/');
    });

    test('keeps non-default ports and strips legacy secrets', () {
      final dsn = CrashReportDsn.parse(
        'https://key:secret@o0.ingest.sentry.io:8443/7',
      );
      expect(dsn.publicKey, 'key');
      expect(
        dsn.envelopeUrl,
        'https://o0.ingest.sentry.io:8443/api/7/envelope/',
      );
    });

    test('rejects malformed DSNs', () {
      for (final bad in [
        '',
        'not-a-url',
        'ftp://key@host/1',
        'https://host/1', // no public key
        'https://key@host/', // no project id
      ]) {
        expect(
          () => CrashReportDsn.parse(bad),
          throwsFormatException,
          reason: 'DSN: "$bad"',
        );
      }
    });
  });

  group('CrashReporter (disabled)', () {
    test('is a silent no-op without a DSN', () async {
      final reporter = CrashReporter(); // never configured
      expect(reporter.isEnabled, isFalse);

      reporter.addBreadcrumb('nope');
      final queued = await reporter.captureError(
        StateError('x'),
        StackTrace.empty,
      );
      expect(queued, isFalse);
      expect(reporter.stats['delivered'], 0);
      expect(reporter.stats['queued'], 0);
    });
  });

  group('CrashReporter (enabled)', () {
    test('sends a well-formed Sentry envelope', () async {
      final client = _ScriptedClient([_resp(200)]);
      final reporter = _reporter(client: client)
        ..configure(
          dsn: 'https://key@errors.test/9',
          release: 'spotimusic@5.0.0+142',
          environment: 'release',
        );

      reporter.addBreadcrumb('resolved stream', category: CrashCategory.streaming);
      final queued = await reporter.captureError(
        StateError('audio pipeline died'),
        StackTrace.fromString(
          '#0      MusicPlayerHandler._play (package:spotimusic/services/music_player_service.dart:1515:5)\n'
          '#1      main (package:spotimusic/main.dart:80:9)',
        ),
        category: CrashCategory.playback,
        context: {'network': 'wifi'},
        fingerprint: ['playback', 'start'],
      );
      expect(queued, isTrue);
      await reporter.flush();

      expect(client.requests.length, 1);
      final request = client.requests.single;
      expect(request.url.toString(), 'https://errors.test/api/9/envelope/');
      expect(
        request.headers['X-Sentry-Auth'],
        contains('sentry_key=key'),
      );
      expect(
        request.headers['Content-Type'],
        'application/x-sentry-envelope',
      );

      final lines = client.bodies.single.split('\n');
      expect(lines.length, 3);
      final header = jsonDecode(lines[0]) as Map<String, dynamic>;
      final itemHeader = jsonDecode(lines[1]) as Map<String, dynamic>;
      final event = jsonDecode(lines[2]) as Map<String, dynamic>;

      expect(header['event_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(itemHeader['type'], 'event');
      expect(event['event_id'], header['event_id']);
      expect(event['platform'], 'dart');
      expect(event['level'], 'error');
      expect(event['logger'], 'playback');
      expect(event['tags'], {'category': 'playback'});
      expect(event['release'], 'spotimusic@5.0.0+142');
      expect(event['environment'], 'release');
      expect(event['fingerprint'], ['playback', 'start']);
      expect(event['extra'], {'network': 'wifi'});

      final exception = event['exception'] as Map<String, dynamic>;
      final value = (exception['values'] as List).single as Map<String, dynamic>;
      expect(value['type'], 'StateError');
      expect(value['value'], contains('audio pipeline died'));
      final frames = (value['stacktrace'] as Map<String, dynamic>)['frames']
          as List<dynamic>;
      expect(frames.length, 2);
      final firstFrame = frames.first as Map<String, dynamic>;
      expect(firstFrame['function'], contains('MusicPlayerHandler'));
      expect(firstFrame['lineno'], 1515);

      final crumbs =
          (event['breadcrumbs'] as Map<String, dynamic>)['values'] as List;
      final onlyCrumb = crumbs.single as Map<String, dynamic>;
      expect(onlyCrumb['message'], 'resolved stream');
      expect(onlyCrumb['category'], 'streaming');
    });

    test('redacts sensitive context recursively and truncates long strings',
        () async {
      final client = _ScriptedClient([_resp(200)]);
      final reporter = _reporter(client: client)
        ..configure(dsn: 'https://key@errors.test/9');

      final long = 'x' * 20000;
      await reporter.captureMessage(
        'm',
        context: {
          'authToken': 'secret-token',
          'Authorization': 'Bearer x',
          'password': 'hunter2',
          'nested': {
            'API_KEY': 'k',
            'sessionCookie': 'c',
            'safe': 42,
            'flag': true,
          },
          'list': ['a', 'b'],
          'long': long,
        },
      );
      await reporter.flush();

      final event =
          jsonDecode(client.bodies.single.split('\n')[2]) as Map<String, dynamic>;
      final extra = event['extra'] as Map<String, dynamic>;
      expect(extra['authToken'], '[redacted]');
      expect(extra['Authorization'], '[redacted]');
      expect(extra['password'], '[redacted]');
      final nested = extra['nested'] as Map<String, dynamic>;
      expect(nested['API_KEY'], '[redacted]');
      expect(nested['sessionCookie'], '[redacted]');
      expect(nested['safe'], 42);
      expect(nested['flag'], isTrue);
      expect(extra['list'], ['a', 'b']);
      expect((extra['long'] as String).length, lessThan(500));
      expect(extra['long'], contains('truncated'));
    });

    test('retries transient failures (429/5xx/network) with backoff, then '
        'delivers', () async {
      final client = _ScriptedClient([
        _resp(429),
        _resp(503),
        _resp(200),
      ]);
      final delays = <Duration>[];
      final reporter = _reporter(client: client, delays: delays)
        ..configure(dsn: 'https://key@errors.test/9');

      await reporter.captureMessage('flaky');
      await reporter.flush();

      expect(client.requests.length, 3);
      expect(delays, [const Duration(milliseconds: 500), const Duration(seconds: 4)]);
      expect(reporter.stats['delivered'], 1);
    });

    test('drops the event after exhausting retries on a network error',
        () async {
      final client = _ScriptedClient([
        Exception('connection refused'),
        Exception('connection refused'),
        Exception('connection refused'),
      ]);
      final reporter = _reporter(client: client)
        ..configure(dsn: 'https://key@errors.test/9');

      await reporter.captureMessage('offline');
      await reporter.flush(timeout: const Duration(milliseconds: 200));

      expect(client.requests.length, 3);
      expect(reporter.stats['dropped_permanent'], 1);
      expect(reporter.lastDeliveryError, contains('connection refused'));
    });

    test('a 400 response drops the event without retrying', () async {
      final client = _ScriptedClient([_resp(400)]);
      final delays = <Duration>[];
      final reporter = _reporter(client: client, delays: delays)
        ..configure(dsn: 'https://key@errors.test/9');

      await reporter.captureMessage('too big');
      await reporter.flush();

      expect(client.requests.length, 1);
      expect(delays, isEmpty);
      expect(reporter.stats['dropped_permanent'], 1);
    });

    test('a 401 response disables the client instead of retrying', () async {
      final client = _ScriptedClient([_resp(401)]);
      final reporter = _reporter(client: client)
        ..configure(dsn: 'https://key@errors.test/9');

      await reporter.captureMessage('bad key');
      await reporter.flush();

      expect(client.requests.length, 1);
      expect(reporter.isEnabled, isFalse);
      // The unsendable event is dropped, not leaked in the queue.
      expect(reporter.stats['queued'], 0);
      // Further captures are refused locally.
      expect(await reporter.captureMessage('after'), isFalse);
    });

    test('rate-limits bursts within the window', () async {
      final client = _ScriptedClient([_resp(200), _resp(200)]);
      var ticks = 0;
      DateTime clock() => DateTime(2026, 1, 1, 12).add(
        Duration(minutes: ticks),
      );
      final reporter = _reporter(
        client: client,
        now: clock,
        rateLimitEvents: 2,
        rateLimitWindow: const Duration(minutes: 10),
      )..configure(dsn: 'https://key@errors.test/9');

      expect(await reporter.captureMessage('a'), isTrue);
      ticks = 1;
      expect(await reporter.captureMessage('b'), isTrue);
      ticks = 2;
      expect(await reporter.captureMessage('c'), isFalse); // over the cap
      expect(reporter.stats['dropped_rate_limit'], 1);

      // Window slides: an hour later the cap is fresh again.
      ticks = 61;
      expect(await reporter.captureMessage('d'), isTrue);
      await reporter.flush();
      expect(reporter.stats['delivered'], 3);
    });

    test('bounds the send queue (oldest dropped first)', () async {
      final stall = Completer<http.Response>();
      final client = _ScriptedClient([stall]);
      final reporter = _reporter(client: client, maxQueueLength: 2)
        ..configure(dsn: 'https://key@errors.test/9');

      await reporter.captureMessage('one');
      await reporter.captureMessage('two');
      // Still stalled on "one": queue = [one, two].
      await Future<void>.delayed(Duration.zero);
      await reporter.captureMessage('three'); // drops "one"
      expect(reporter.stats['dropped_queue_limit'], 1);
      expect(reporter.stats['queued'], 2);

      stall.complete(_resp(200)); // unblock drain; "two"/"three" follow.
      await reporter.flush();
      expect(client.requests.length, 3);
      expect(reporter.stats['delivered'], 3);
    });

    test('breadcrumb ring buffer keeps only the newest entries', () async {
      final client = _ScriptedClient([_resp(200)]);
      final reporter = _reporter(client: client, maxBreadcrumbs: 3)
        ..configure(dsn: 'https://key@errors.test/9');

      for (var i = 0; i < 5; i++) {
        reporter.addBreadcrumb('b$i');
      }
      await reporter.captureMessage('event');
      await reporter.flush();

      final event =
          jsonDecode(client.bodies.single.split('\n')[2]) as Map<String, dynamic>;
      final crumbs =
          (event['breadcrumbs'] as Map<String, dynamic>)['values'] as List;
      expect(
        crumbs
            .map((c) => (c as Map<String, dynamic>)['message'])
            .toList(),
        ['b2', 'b3', 'b4'],
      );
    });

    test('reset clears all state', () async {
      final client = _ScriptedClient(<Object>[]);
      final reporter = _reporter(client: client)
        ..configure(dsn: 'https://key@errors.test/9');
      reporter.addBreadcrumb('x');
      await reporter.captureMessage('y');
      reporter.reset();

      expect(reporter.isEnabled, isFalse);
      expect(reporter.stats['queued'], 0);
      expect(reporter.lastDeliveryError, isNull);
    });
  });
}
