/// Cross-device playback continuity (Task 10 / Milestone 1 §3).
///
/// Mirrors the backend contract in `backend/cloud/continuity.go`:
///
/// * `GET  /v1/cloud/continuity` → `{state, resumeMs, serverTime}` — the
///   server already applies the wall-clock correction, so the client never
///   trusts its own clock;
/// * `PUT  /v1/cloud/continuity` → `{status: "ok"}` — last-writer-wins;
/// * `GET  /v1/cloud/events`    → WebSocket event stream carrying
///   `kind: "continuity"` hand-off notifications.
///
/// Client behaviour:
///
/// * While a track plays, a [ContinuitySnapshot] is uploaded every 3 s
///   (immediately on pause / track change / backgrounding) so the freshest
///   position is always <3 s old on the server;
/// * When another device sends a hand-off (or this app returns to the
///   foreground) and this device is *idle*, playback auto-resumes at the
///   corrected position. A track that is not present as a local file on
///   this device cannot be resumed and is reported instead of guessed at.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart' show WidgetRef;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../providers/cloud_providers.dart';
import '../providers/ecosystem_providers.dart' show accountServiceProvider;
import '../providers/music_player_provider.dart';
import '../services/music_player_service.dart';
import '../utils/logger.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One cross-device "where am I in my music" snapshot.
///
/// Field names are the wire contract (`trackId`/`positionMs`/`updatedAt` …)
/// shared with `backend/cloud/continuity.go` — do not rename.
class ContinuitySnapshot {
  const ContinuitySnapshot({
    required this.deviceId,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.queue,
    required this.queueIndex,
    required this.updatedAt,
  });

  /// Stable id of the device that produced the snapshot.
  final String deviceId;

  /// Track identifier (for local playback this is the file path, which is
  /// the id [audio.MediaItem] carries through audio_service).
  final String trackId;

  final String title;
  final String artist;
  final String artworkUrl;

  /// Position inside [trackId] at [updatedAt], milliseconds.
  final int positionMs;
  final int durationMs;

  /// Whether the sending device was actively playing at [updatedAt].
  final bool playing;

  /// Snapshot of the sending device's queue (track ids), around
  /// [queueIndex].
  final List<String> queue;
  final int queueIndex;

  /// When the snapshot was taken (UTC).
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'playing': playing,
        'queue': queue,
        'queueIndex': queueIndex,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  /// Lenient parser: malformed or partial payloads yield null instead of an
  /// exception so one bad frame cannot take down the event stream.
  static ContinuitySnapshot? tryFromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      final trackId = json['trackId']?.toString().trim() ?? '';
      if (trackId.isEmpty) return null;
      final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
      if (updatedAt == null) return null;
      final queue = <String>[];
      if (json['queue'] is List) {
        for (final entry in (json['queue'] as List).cast<Object?>()) {
          final id = entry?.toString().trim() ?? '';
          if (id.isNotEmpty) queue.add(id);
        }
      }
      return ContinuitySnapshot(
        deviceId: json['deviceId']?.toString() ?? '',
        trackId: trackId,
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        artworkUrl: json['artworkUrl']?.toString() ?? '',
        positionMs: _asInt(json['positionMs']).clamp(0, 1 << 31),
        durationMs: _asInt(json['durationMs']).clamp(0, 1 << 31),
        playing: json['playing'] == true,
        queue: queue,
        queueIndex: _asInt(json['queueIndex']).clamp(0, 1 << 31),
        updatedAt: updatedAt.toUtc(),
      );
    } on Object {
      return null;
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

/// Result of `GET /v1/cloud/continuity`.
class ContinuityFetchResult {
  const ContinuityFetchResult({
    required this.state,
    required this.resumeMs,
    required this.serverTime,
  });

  /// Latest snapshot (null = the user has never played on any device).
  final ContinuitySnapshot? state;

  /// Server-corrected resume offset for [state] (position plus elapsed
  /// wall-clock time while playing), milliseconds.
  final int? resumeMs;

  /// Server clock, for clock-skew estimation.
  final DateTime serverTime;
}

/// A `kind: "continuity"` event from the realtime stream.
class ContinuityEvent {
  const ContinuityEvent({
    required this.snapshot,
    required this.origin,
    required this.at,
  });

  final ContinuitySnapshot snapshot;

  /// Device id of the sender (never this device — filtered upstream).
  final String? origin;

  /// Server time the event was emitted.
  final DateTime at;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

typedef WebSocketFactory =
    Future<io.WebSocket> Function(Uri uri, Map<String, String> headers);

/// Thin client for the continuity endpoints. No Riverpod, no Flutter —
/// fully unit-testable with an injected [http.Client] and WebSocket factory.
final class PlaybackContinuityClient {
  PlaybackContinuityClient({
    required String baseUrl,
    http.Client? httpClient,
    required Future<String?> Function() accessToken,
    required Future<String> Function() deviceId,
    @visibleForTesting WebSocketFactory? webSocketFactory,
    @visibleForTesting Duration idleTimeout = const Duration(seconds: 75),
  })  : _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _client = httpClient ?? http.Client(),
        _accessToken = accessToken,
        _deviceId = deviceId,
        _wsFactory = webSocketFactory ??
            ((uri, headers) => io.WebSocket.connect(uri.toString(), headers: headers)),
        _idleTimeout = idleTimeout {
    if (_base.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must not be empty');
    }
  }

  final String _base;
  final http.Client _client;
  final Future<String?> Function() _accessToken;
  final Future<String> Function() _deviceId;
  final WebSocketFactory _wsFactory;
  final Duration _idleTimeout;

  _ContinuityEvents? _events;
  bool _closed = false;

  Future<Map<String, String>> _headers(String token) async => <String, String>{
        'Authorization': 'Bearer $token',
        'X-Device-Id': await _deviceId(),
      };

  /// Returns the latest snapshot, or null when the user is not signed in or
  /// the server has no continuity storage configured (HTTP 501).
  Future<ContinuityFetchResult?> fetch() async {
    if (_closed) return null;
    final token = await _accessToken();
    if (token == null || token.isEmpty) return null;
    final response = await _client
        .get(Uri.parse('$_base/v1/cloud/continuity'), headers: await _headers(token));
    if (response.statusCode == 501) return null;
    if (response.statusCode != 200) {
      throw http.ClientException(
        'continuity fetch failed (${response.statusCode})',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final serverTime =
        DateTime.tryParse(decoded['serverTime']?.toString() ?? '');
    if (serverTime == null) return null;
    return ContinuityFetchResult(
      state: ContinuitySnapshot.tryFromJson(decoded['state']),
      resumeMs: ContinuitySnapshot._asInt(decoded['resumeMs']),
      serverTime: serverTime,
    );
  }

  /// Uploads a snapshot. Returns false (without throwing) when signed out,
  /// storage is unconfigured, or the network failed — continuity is a
  /// best-effort background feature and must never surface errors to the
  /// user.
  Future<bool> upload(ContinuitySnapshot snapshot) async {
    if (_closed) return false;
    final token = await _accessToken();
    if (token == null || token.isEmpty) return false;
    try {
      final hdrs = await _headers(token);
      final response = await _client.put(
        Uri.parse('$_base/v1/cloud/continuity'),
        headers: <String, String>{
          ...hdrs,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(snapshot.toJson()),
      );
      if (response.statusCode == 501) return false;
      return response.statusCode == 200;
    } on io.SocketException {
      return false;
    } on io.TlsException {
      return false;
    } on http.ClientException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// Opens the realtime hand-off stream. The connection is opened lazily,
  /// survives transient failures with capped exponential backoff, and is
  /// terminated by [disconnect]. Events from this device's own id are
  /// filtered out so a sender never resumes its own echo.
  Future<Stream<ContinuityEvent>> connect() async {
    if (_closed) {
      return const Stream<ContinuityEvent>.empty();
    }
    if (_events == null) {
      final selfId = await _deviceId();
      _events = _ContinuityEvents(
        accessToken: _accessToken,
        deviceId: _deviceId,
        base: _base,
        factory: _wsFactory,
        idleTimeout: _idleTimeout,
        selfDeviceId: selfId,
      );
      _events!.start();
    }
    return _events!.stream;
  }

  Future<void> disconnect() async {
    await _events?.stop();
    _events = null;
  }

  void close() {
    _closed = true;
    unawaited(disconnect());
    _client.close();
  }
}

/// Reconnecting WebSocket subscription for the `/v1/cloud/events` stream.
final class _ContinuityEvents {
  _ContinuityEvents({
    required Future<String?> Function() accessToken,
    required Future<String> Function() deviceId,
    required String base,
    required WebSocketFactory factory,
    required Duration idleTimeout,
    required String selfDeviceId,
  })  : _accessToken = accessToken,
        _deviceId = deviceId,
        _uri = Uri.parse(
          '${base.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://')}/v1/cloud/events',
        ),
        _factory = factory,
        _idleTimeout = idleTimeout,
        _selfDeviceId = selfDeviceId;

  final Future<String?> Function() _accessToken;
  final Future<String> Function() _deviceId;
  final Uri _uri;
  final WebSocketFactory _factory;
  final Duration _idleTimeout;
  final String _selfDeviceId;

  final StreamController<ContinuityEvent> _controller =
      StreamController<ContinuityEvent>.broadcast();
  final Completer<void> _stopped = Completer<void>();

  io.WebSocket? _socket;
  Timer? _watchdog;
  bool _running = false;
  int _generation = 0;

  Stream<ContinuityEvent> get stream => _controller.stream;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    var backoffMs = 1000;
    while (_running && !_controller.isClosed) {
      final generation = ++_generation;
      io.WebSocket? socket;
      Timer? watchdog;
      try {
        final token = await _accessToken();
        if (token == null || token.isEmpty || !_running || generation != _generation) {
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }
        socket = await _factory(
          _uri,
          <String, String>{
            'Authorization': 'Bearer $token',
            'X-Device-Id': await _deviceId(),
          },
        );
        _socket = socket;
        backoffMs = 1000;
        // The server pings every 25 s; 3 missed pings means the socket is
        // dead even though no error surfaced (common on mobile NATs).
        watchdog = Timer(_idleTimeout, () {
          socket?.close();
        });
        _watchdog = watchdog;
        await for (final frame in socket) {
          if (generation != _generation || !_running) break;
          watchdog?.cancel();
          watchdog = Timer(_idleTimeout, () {
            socket?.close();
          });
          _watchdog = watchdog;
          final event = _decode(frame);
          if (event != null && !_controller.isClosed) {
            _controller.add(event);
          }
        }
      } on Object {
        // Reconnect with backoff below.
      } finally {
        watchdog?.cancel();
        if (identical(_watchdog, watchdog)) _watchdog = null;
        if (identical(_socket, socket)) _socket = null;
      }
      if (!_running || generation != _generation) break;
      await Future<void>.delayed(Duration(milliseconds: backoffMs));
      backoffMs = (backoffMs * 2).clamp(1000, 30000);
    }
    if (!_stopped.isCompleted) _stopped.complete();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  ContinuityEvent? _decode(Object? frame) {
    if (frame is! String) return null;
    try {
      final Object? decoded = jsonDecode(frame);
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['kind'] != 'continuity') return null;
      final origin = decoded['origin']?.toString();
      if (origin != null && origin == _selfDeviceId) return null;
      final snapshot = ContinuitySnapshot.tryFromJson(decoded['payload']);
      if (snapshot == null) return null;
      final at =
          DateTime.tryParse(decoded['at']?.toString() ?? '') ?? DateTime.now();
      return ContinuityEvent(snapshot: snapshot, origin: origin, at: at);
    } on FormatException {
      return null;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _generation++;
    _watchdog?.cancel();
    _watchdog = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } on Object {
      // Socket already gone.
    }
    try {
      await _stopped.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The loop is stuck in a reconnect sleep; it will exit on its own.
    }
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

// ---------------------------------------------------------------------------
// App-level controller
// ---------------------------------------------------------------------------

/// Pushes the local playback position to the cloud and resumes playback
/// handed off from another device.
///
/// Created once by the app shell (see `main.dart`) with the shell's
/// [Ref]; every dependency is read lazily so a missing cloud config keeps
/// the whole feature a silent no-op.
final class PlaybackSyncController {
  PlaybackSyncController(this._ref) {
    _log = AppLogger('PlaybackSync');
  }

  final WidgetRef _ref;
  late final AppLogger _log;

  /// How often the position is refreshed while a track plays. The backend
  /// and the 3 s resume budget in the spec both assume this cadence.
  static const Duration pushInterval = Duration(seconds: 3);

  PlaybackContinuityClient? _client;
  String _clientBase = '';
  StreamSubscription<ContinuityEvent>? _eventSub;
  StreamSubscription<audio.MediaItem?>? _mediaSub;
  StreamSubscription<audio.PlaybackState>? _stateSub;
  StreamSubscription<List<audio.MediaItem>>? _queueSub;
  Timer? _pushTimer;
  Timer? _configTimer;

  audio.MediaItem? _lastItem;
  List<String> _queueIds = const <String>[];
  ContinuitySnapshot? _lastPushed;
  String? _resumedTrackId;
  bool _started = false;
  bool _stopping = false;

  void start() {
    if (_started) return;
    _started = true;

    _mediaSub = musicPlayerMediaItemEvents().listen(
      (item) {
        _lastItem = item;
        _schedulePush(immediate: true);
      },
      onError: (Object _) {},
    );
    _stateSub = musicPlayerPlaybackStateEvents().listen(
      (state) => _schedulePush(immediate: !state.playing),
      onError: (Object _) {},
    );
    _queueSub = musicPlayerQueueEvents().listen(
      (queue) {
        _queueIds = queue
            .map((item) => item.id)
            .where((id) => id.isNotEmpty)
            .toList(growable: false);
      },
      onError: (Object _) {},
    );

    unawaited(_connectEvents());

    // The server URL is a user-editable setting; rebuild the client when it
    // changes so pushes and the event stream follow the new deployment.
    _configTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _ensureClient();
    });
  }

  /// Stops subscriptions, flushes one final snapshot and tears the client
  /// down. Idempotent.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final client = _client;
    _mediaSub?.cancel();
    _stateSub?.cancel();
    _queueSub?.cancel();
    _eventSub?.cancel();
    _pushTimer?.cancel();
    _configTimer?.cancel();
    _mediaSub = null;
    _stateSub = null;
    _queueSub = null;
    _eventSub = null;
    _pushTimer = null;
    _configTimer = null;
    if (client != null) {
      final snapshot = _buildSnapshot();
      if (snapshot != null) {
        try {
          await client.upload(snapshot);
        } on Object catch (error) {
          _log.w('final continuity push failed: $error');
        }
      }
      client.close();
      _client = null;
      _clientBase = '';
    }
    _started = false;
    _stopping = false;
  }

  /// Uploads the current position right away (used when the app goes to the
  /// background — the last reliable moment before the OS may suspend us).
  Future<void> onBackground() async {
    final client = _ensureClient();
    final snapshot = _buildSnapshot();
    if (client == null || snapshot == null) return;
    _pushTimer?.cancel();
    _pushTimer = null;
    try {
      if (await client.upload(snapshot)) {
        _lastPushed = snapshot;
      }
    } on Object catch (error) {
      _log.w('background continuity push failed: $error');
    }
  }

  /// Foreground resume: when this device is idle and the cloud holds a
  /// fresher snapshot from another device, resume it. Never interrupts a
  /// track that is playing locally.
  Future<void> resumeFromCloudIfIdle() async {
    if (musicPlayerHandler?.playbackState.value.playing ?? false) return;
    final client = _ensureClient();
    if (client == null) return;
    ContinuityFetchResult? result;
    try {
      result = await client.fetch();
    } on Object catch (error) {
      _log.w('continuity fetch failed: $error');
      return;
    }
    final snapshot = result?.state;
    if (result == null || snapshot == null) return;
    // Never auto-restart a track this device already resumed this session.
    if (snapshot.trackId == _resumedTrackId) return;
    final resumeMs =
        result.resumeMs ?? _resumeMsFor(snapshot, result.serverTime);
    await _resumeFrom(snapshot, resumeMs, source: 'foreground');
  }

  // -- internals ------------------------------------------------------------

  Future<void> _connectEvents() async {
    final client = _ensureClient();
    if (client == null || _eventSub != null) return;
    try {
      _eventSub = (await client.connect()).listen(
        (event) => unawaited(_handleHandoff(event)),
        onError: (Object error) {
          _log.w('continuity event stream error: $error');
        },
      );
    } on Object catch (error) {
      _log.w('continuity events unavailable: $error');
    }
  }

  Future<void> _handleHandoff(ContinuityEvent event) async {
    // Only ever auto-resume when idle: a hand-off must never interrupt the
    // user who is actively listening on this device.
    if (musicPlayerHandler?.playbackState.value.playing ?? false) return;
    final snapshot = event.snapshot;
    if (snapshot.trackId == _resumedTrackId) return;
    final resumeMs = _resumeMsFor(snapshot, event.at);
    await _resumeFrom(snapshot, resumeMs, source: 'event');
  }

  int _resumeMsFor(ContinuitySnapshot snapshot, DateTime at) {
    var ms = snapshot.positionMs;
    if (snapshot.playing) {
      final elapsed = at.difference(snapshot.updatedAt);
      if (elapsed > Duration.zero) {
        ms += elapsed.inMilliseconds;
      }
    }
    if (snapshot.durationMs > 0 && ms > snapshot.durationMs) {
      ms = snapshot.durationMs;
    }
    return ms.clamp(0, 1 << 30);
  }

  Future<void> _resumeFrom(
    ContinuitySnapshot snapshot,
    int resumeMs, {
    required String source,
  }) async {
    final items = _localItemsFor(snapshot);
    if (items.isEmpty) {
      _log.i(
        'continuity resume skipped ($source): '
        '“${snapshot.title}” is not available as a local file on this device',
      );
      return;
    }
    try {
      final controller = _ref.read(musicPlayerControllerProvider);
      await controller.playAll(items, initialIndex: items.length - 1);
      // Give the engine a beat to load the source before seeking; without
      // the delay a seek can land before the player is ready.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (resumeMs > 250) {
        await controller.seek(Duration(milliseconds: resumeMs));
      }
      _resumedTrackId = snapshot.trackId;
      _log.i(
        'continuity resumed ($source): “${snapshot.title}” @ '
        '${resumeMs ~/ 1000}s from ${snapshot.deviceId}',
      );
    } on Object catch (error) {
      _log.w('continuity resume failed ($source): $error');
    }
  }

  /// Rebuilds the hand-off queue from local files that actually exist on
  /// this device, with the handed-off track last so [initialIndex] is
  /// trivial. Entries without a resolvable file are dropped rather than
  /// producing broken queue rows.
  List<PlayableMedia> _localItemsFor(ContinuitySnapshot snapshot) {
    final items = <PlayableMedia>[];
    final seen = <String>{};
    for (final id in snapshot.queue) {
      if (id == snapshot.trackId) continue;
      if (!seen.add(id)) continue;
      if (!_isExistingLocalFile(id)) continue;
      items.add(_localItem(id));
    }
    if (!_isExistingLocalFile(snapshot.trackId)) return const <PlayableMedia>[];
    items.add(PlayableMedia(
      id: snapshot.trackId,
      source: snapshot.trackId,
      title: snapshot.title.isEmpty
          ? p.basenameWithoutExtension(snapshot.trackId)
          : snapshot.title,
      artist: snapshot.artist,
      artUri: snapshot.artworkUrl.isEmpty ? null : snapshot.artworkUrl,
    ));
    return items;
  }

  PlayableMedia _localItem(String path) => PlayableMedia(
        id: path,
        source: path,
        title: p.basenameWithoutExtension(path),
        artist: '',
      );

  bool _isExistingLocalFile(String id) {
    if (id.isEmpty) return false;
    if (id.startsWith('http://') ||
        id.startsWith('https://') ||
        id.startsWith('content://') ||
        id.startsWith('file://')) {
      // file:// URIs point at this device's own files; everything else is a
      // remote/provider id that cannot be resumed generically.
      if (!id.startsWith('file://')) return false;
      id = Uri.tryParse(id)?.toFilePath() ?? id;
    }
    return io.File(id).existsSync();
  }

  void _schedulePush({required bool immediate}) {
    if (_stopping) return;
    final client = _ensureClient();
    if (client == null) return;
    final snapshot = _buildSnapshot();
    if (snapshot == null) {
      _pushTimer?.cancel();
      _pushTimer = null;
      return;
    }
    final last = _lastPushed;
    final trackChanged = last?.trackId != snapshot.trackId;
    final pushNow = immediate || trackChanged || last == null;
    if (pushNow) {
      _pushTimer?.cancel();
      _pushTimer = null;
      unawaited(_push(client, snapshot));
    } else {
      _pushTimer ??= Timer(pushInterval, () {
        _pushTimer = null;
        final c = _ensureClient();
        final s = _buildSnapshot();
        if (c != null && s != null) {
          unawaited(_push(c, s));
        }
      });
    }
  }

  Future<void> _push(
    PlaybackContinuityClient client,
    ContinuitySnapshot snapshot,
  ) async {
    try {
      if (await client.upload(snapshot)) {
        _lastPushed = snapshot;
      }
    } on Object catch (error) {
      _log.w('continuity push failed: $error');
    }
  }

  ContinuitySnapshot? _buildSnapshot() {
    final item = _lastItem;
    if (item == null || item.id.isEmpty) return null;
    if (_client != null && _cachedDeviceId.isEmpty) _refreshDeviceId();
    final state = musicPlayerHandler?.playbackState.value;
    var queue = _queueIds;
    var index = queue.indexOf(item.id);
    if (index < 0) {
      index = 0;
      if (!queue.contains(item.id)) {
        queue = <String>[item.id, ...queue];
      }
    }
    return ContinuitySnapshot(
      deviceId: _cachedDeviceId,
      trackId: item.id,
      title: item.title,
      artist: item.artist ?? '',
      artworkUrl: item.artUri?.toString() ?? '',
      positionMs: state?.position.inMilliseconds ?? 0,
      durationMs: (item.duration ?? Duration.zero).inMilliseconds,
      playing: state?.playing ?? false,
      queue: queue,
      queueIndex: index,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  String _cachedDeviceId = '';

  /// Keeps [deviceId] fresh for the snapshot builder without making
  /// [ContinuitySnapshot] construction async. The id is generated once and
  /// then stable, so a cached read is safe on the hot path.
  void _refreshDeviceId() {
    unawaited(
      _ref
          .read(cloudAccountManagerProvider)
          .deviceId()
          .then((id) => _cachedDeviceId = id)
          .catchError((Object _) => ''),
    );
  }

  PlaybackContinuityClient? _ensureClient() {
    if (_stopping) return null;
    final server = _ref.read(cloudServerConfigProvider);
    if (!server.isConfigured) {
      // The user removed the server: drop any live client so pushes and
      // the event stream stop following the old deployment.
      if (_client != null) {
        unawaited(_eventsTearDown());
        _client?.close();
        _client = null;
        _clientBase = '';
      }
      return null;
    }
    if (_client != null && _clientBase == server.base) {
      if (_cachedDeviceId.isEmpty) _refreshDeviceId();
      return _client;
    }
    // Rebuild (config changed or first use).
    unawaited(_eventsTearDown());
    _client?.close();
    _client = null;
    _clientBase = '';
    if (_cachedDeviceId.isEmpty) _refreshDeviceId();
    final account = _ref.read(accountServiceProvider);
    final deviceManager = _ref.read(cloudAccountManagerProvider);
    final client = PlaybackContinuityClient(
      baseUrl: server.base,
      accessToken: account.accessToken,
      deviceId: deviceManager.deviceId,
    );
    _client = client;
    _clientBase = server.base;
    _lastPushed = null;
    _refreshDeviceId();
    unawaited(_connectEvents());
    return client;
  }

  Future<void> _eventsTearDown() async {
    await _eventSub?.cancel();
    _eventSub = null;
  }
}
