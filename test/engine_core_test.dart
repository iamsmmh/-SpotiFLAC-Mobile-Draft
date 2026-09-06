import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/engine/track_identity.dart';

void main() {
  group('TrackTextNormalizer', () {
    test('strips diacritics and punctuation', () {
      expect(TrackTextNormalizer.normalize('Café — Live!'), 'cafe live');
      expect(TrackTextNormalizer.normalize('À propos (Remastered 2020)'), 'a propos');
    });

    test('drops parentheticals and leading "the"', () {
      expect(TrackTextNormalizer.normalize('The Chain (Live)'), 'chain');
    });

    test('empty input stays empty', () {
      expect(TrackTextNormalizer.normalize(null), '');
      expect(TrackTextNormalizer.normalize('  '), '');
    });
  });

  group('StringSimilarity', () {
    test('exact strings score 1.0', () {
      expect(StringSimilarity.similarity('Blinding Lights', 'Blinding Lights'), 1.0);
    });

    test('typos stay close', () {
      final score = StringSimilarity.similarity('Blinding Lights', 'Blinding Light');
      expect(score, greaterThanOrEqualTo(0.9));
    });

    test('transpositions are handled', () {
      expect(
        StringSimilarity.similarity('Galfa', 'Gafla'),
        greaterThanOrEqualTo(0.79),
      );
    });
  });

  group('TrackIdentityMatcher', () {
    TrackIdentityInput input({
      String title = 'Karma',
      String artist = 'Taylor Swift',
      String? album = 'Midnights',
      String? isrc,
      int duration = 200,
    }) => TrackIdentityInput(
      title: title,
      artist: artist,
      album: album ?? '',
      isrc: isrc,
      durationSeconds: duration,
    );

    test('exact ISRC wins regardless of title formatting', () {
      const matcher = TrackIdentityMatcher();
      expect(
        matcher.isSameTrack(
          input(title: 'Karma', isrc: 'USUM22112345'),
          input(title: 'Karma (Explicit)', isrc: 'USUM22112345', duration: 201),
        ),
        isTrue,
      );
    });

    test('same title + artist + duration matched', () {
      const matcher = TrackIdentityMatcher();
      expect(
        matcher.isSameTrack(
          input(),
          input(duration: 195),
        ),
        isTrue,
      );
    });

    test('different artist with same title is not a match', () {
      const matcher = TrackIdentityMatcher();
      expect(
        matcher.isSameTrack(input(), input(artist: 'Amaranthe')),
        isFalse,
      );
    });

    test('duration far apart is not a match', () {
      const matcher = TrackIdentityMatcher();
      expect(matcher.isSameTrack(input(), input(duration: 260)), isFalse);
    });

    test('strongly disagreeing albums block the match', () {
      const matcher = TrackIdentityMatcher();
      expect(
        matcher.isSameTrack(
          input(album: 'Midnights'),
          input(album: 'Reputation'),
        ),
        isFalse,
      );
    });

    test('score combines the signals', () {
      const matcher = TrackIdentityMatcher();
      final score = matcher.score(
        input(isrc: 'USUM22112345'),
        input(isrc: 'USUM22112345'),
      );
      expect(score.overall, greaterThanOrEqualTo(0.78));
      expect(score.isExactMatch, isTrue);
    });
  });

  group('TrackIdentityIndex', () {
    test('merges exact duplicates and splits fuzzy collisions', () {
      final index = TrackIdentityIndex();
      final first = index.insert(
        TrackIdentityInput(
          title: 'Song',
          artist: 'Artist',
          durationSeconds: 100,
        ),
      );
      final dupe = index.insert(
        TrackIdentityInput(
          title: 'Song',
          artist: 'Artist',
          durationSeconds: 101,
        ),
      );
      final different = index.insert(
        TrackIdentityInput(
          title: 'Song',
          artist: 'Someone Else',
          durationSeconds: 100,
        ),
      );

      expect(dupe.stableId, first.stableId);
      expect(index.membersOf(first).length, 2);
      expect(different.stableId, isNot(first.stableId));
      expect(index.length, 2);
    });
  });

  group('AudioQualityLevel', () {
    test('ladder ordering is monotonic', () {
      expect(AudioQualityLevel.low.rank, lessThan(AudioQualityLevel.high.rank));
      expect(AudioQualityLevel.lossless.rank, greaterThan(AudioQualityLevel.high.rank));
      expect(AudioQualityLevel.hires.rank, greaterThan(AudioQualityLevel.lossless.rank));
    });

    test('fromLabel maps legacy quality strings', () {
      expect(AudioQualityLevel.fromLabel('FLAC'), AudioQualityLevel.lossless);
      expect(AudioQualityLevel.fromLabel('hi-res'), AudioQualityLevel.hires);
      expect(AudioQualityLevel.fromLabel('320'), AudioQualityLevel.auto);
      expect(AudioQualityLevel.fromLabel('lossless'), AudioQualityLevel.lossless);
    });

    test('policy maps network profiles to ladder steps', () {
      const policy = QualityPolicy();
      expect(policy.levelFor(NetworkProfile.wifi), AudioQualityLevel.lossless);
      expect(policy.levelFor(NetworkProfile.mobile), AudioQualityLevel.high);
      expect(policy.levelFor(NetworkProfile.poor), AudioQualityLevel.normal);
    });

    test('stepDown/Up never leaves the ladder', () {
      expect(
        QualityPolicy.stepDown(AudioQualityLevel.low),
        AudioQualityLevel.low,
      );
      expect(
        QualityPolicy.stepUp(AudioQualityLevel.lossless),
        AudioQualityLevel.hires,
      );
    });
  });

  group('AudioCharacteristics', () {
    test('compactLabel composes codec + bit depth + sample rate', () {
      const characteristics = AudioCharacteristics(
        codec: 'FLAC',
        bitDepth: 24,
        sampleRateHz: 96000,
        lossless: true,
      );
      expect(characteristics.compactLabel, 'FLAC 24-bit/96kHz');
      expect(characteristics.detailLines, contains('Lossless'));
    });

    test('json roundtrip preserves fields', () {
      const characteristics = AudioCharacteristics(
        codec: 'AAC',
        bitrateKbps: 256,
        channels: 2,
        fileSizeBytes: 4096,
      );
      final restored = AudioCharacteristics.fromJson(
        characteristics.toJson(),
      );
      expect(restored.codec, 'AAC');
      expect(restored.bitrateKbps, 256);
      expect(restored.channels, 2);
      expect(restored.lossless, isFalse);
    });
  });

  group('ProviderHealth', () {
    test('failures drive exponential backoff and offline state', () {
      var health = ProviderHealth.initial('p1');
      expect(health.isAvailable, isTrue);
      health = health.recordFailure();
      expect(health.isAvailable, isFalse); // backoff window open
      health = health.recordSuccess();
      expect(health.isAvailable, isTrue);
      expect(health.successRate, closeTo(0.5, 0.001));
    });

    test('permanently disables after 5 consecutive failures', () {
      var health = ProviderHealth.initial('p1');
      for (var i = 1; i <= 5; i++) {
        health = health.recordFailure();
        if (i < 5) {
          // Backoff makes the provider unavailable, but it must stay *online*
          // (eligible again after the window) until the 5th failure.
          expect(health.online, isTrue, reason: 'failure #$i');
        }
      }
      expect(health.online, isFalse, reason: '5 failures in a row');
      expect(health.consecutiveFailures, 5);
      expect(health.isAvailable, isFalse);
    });

    test('successes restore reliability', () {
      final fresh = ProviderHealth.initial('p1');
      expect(fresh.score, 1.0);
    });
  });

  group('ProviderHealthRegistry', () {
    test('bounded snapshot and reset', () {
      final registry = ProviderHealthRegistry();
      registry.recordFailure('p1');
      registry.recordSuccess('p1', latencyMs: 120);
      expect(registry.healthOf('p1').failureCount, 1);
      registry.reset('p1');
      expect(registry.healthOf('p1').failureCount, 0);
    });
  });

  group('StreamDescriptor.copyWith', () {
    StreamDescriptor base() => StreamDescriptor(
      id: 't1',
      providerId: 'p',
      kind: StreamSourceKind.httpStream,
      uri: 'https://example.test/1',
      expiresAt: DateTime.utc(2030),
      validFrom: DateTime.utc(2026),
      latencyMs: 42,
      priority: 3,
    );

    test('omitted nullable fields keep their previous values', () {
      final copy = base().copyWith(uri: 'https://example.test/2');
      expect(copy.uri, 'https://example.test/2');
      expect(copy.expiresAt, DateTime.utc(2030));
      expect(copy.validFrom, DateTime.utc(2026));
      expect(copy.latencyMs, 42);
      expect(copy.priority, 3);
    });

    test('explicit null clears expiry, validFrom, and latency', () {
      final copy = base().copyWith(
        expiresAt: null,
        validFrom: null,
        latencyMs: null,
      );
      expect(copy.expiresAt, isNull);
      expect(copy.validFrom, isNull);
      expect(copy.latencyMs, isNull);
      // Non-nullable fields still carry over.
      expect(copy.priority, 3);
      expect(copy.uri, 'https://example.test/1');
    });

    test('explicit values still replace existing ones', () {
      final copy = base().copyWith(
        expiresAt: DateTime.utc(2031),
        latencyMs: 7,
      );
      expect(copy.expiresAt, DateTime.utc(2031));
      expect(copy.validFrom, DateTime.utc(2026));
      expect(copy.latencyMs, 7);
    });
  });

  group('StreamSourceResolver', () {
    StreamDescriptor source({
      required String id,
      required String provider,
      AudioQualityLevel quality = AudioQualityLevel.high,
      int latencyMs = 100,
      int priority = 0,
      DateTime? expiresAt,
    }) => StreamDescriptor(
      id: id,
      providerId: provider,
      kind: StreamSourceKind.httpStream,
      uri: 'https://example.test/$id',
      quality: quality,
      latencyMs: latencyMs,
      priority: priority,
      expiresAt: expiresAt,
    );

    test('ranks quality fit over latency for the requested profile', () {
      final health = ProviderHealthRegistry();
      final resolver = StreamSourceResolver(health: health);
      final ranked = resolver.candidates(
        [
          source(id: 'a', provider: 'p1', quality: AudioQualityLevel.normal, latencyMs: 10),
          source(id: 'b', provider: 'p2', quality: AudioQualityLevel.lossless, latencyMs: 400),
        ],
        requested: AudioQualityLevel.high,
      );
      expect(ranked.first.providerId, 'p2');
    });

    test('expired and backoff providers drop out of the candidate set', () {
      final health = ProviderHealthRegistry();
      health.recordFailure('dead');
      final resolver = StreamSourceResolver(health: health);
      final ranked = resolver.candidates([
        source(id: 'ok', provider: 'ok'),
        source(
          id: 'expired',
          provider: 'dead2',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        source(id: 'down', provider: 'dead'),
      ]);
      expect(ranked.map((s) => s.id), ['ok']);
    });

    test('deterministic tiebreak', () {
      final health = ProviderHealthRegistry();
      final resolver = StreamSourceResolver(health: health);
      final a = resolver.candidates([
        source(id: 'x', provider: 'alpha'),
        source(id: 'y', provider: 'beta'),
      ]);
      final b = resolver.candidates([
        source(id: 'x', provider: 'alpha'),
        source(id: 'y', provider: 'beta'),
      ]);
      expect(a.map((s) => s.id), b.map((s) => s.id));
    });
  });

  group('StreamingSessionController', () {
    StreamDescriptor source(String id, String provider) => StreamDescriptor(
      id: id,
      providerId: provider,
      kind: StreamSourceKind.httpStream,
      uri: 'https://example.test/$id',
      quality: AudioQualityLevel.high,
    );

    test('resolves to the best candidate', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final outcome = session.resolve([
        source('a', 'p1'),
        source('b', 'p2'),
      ]);
      expect(outcome.resolved?.id, 'a');
      expect(outcome.alternatives.map((s) => s.id), ['b']);
      expect(session.state.phase, StreamPhase.preflighting);
    });

    test('failure falls back to the next source', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final outcome = session.resolve([
        source('a', 'p1'),
        source('b', 'p2'),
      ]);
      final next = session.onFailure(
        StreamFailure(kind: StreamFailureKind.network, providerId: 'p1'),
        outcome.resolved!,
        outcome.alternatives,
      );
      expect(next?.id, 'b');
      expect(session.state.phase, StreamPhase.fallingBack);
    });

    test('exhausted candidates become failed', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final outcome = session.resolve([source('a', 'p1')]);
      final next = session.onFailure(
        StreamFailure(kind: StreamFailureKind.network, providerId: 'p1'),
        outcome.resolved!,
        outcome.alternatives,
      );
      expect(next, isNull);
      expect(session.state.phase, StreamPhase.failed);
    });

    test('retry delay respects the retry budget', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final first = session.retryDelay(
        StreamFailure(kind: StreamFailureKind.timeout, providerId: 'p1'),
        3,
      );
      expect(first, isNotNull);
      final exhausted = session.retryDelay(
        StreamFailure(kind: StreamFailureKind.timeout, providerId: 'p1'),
        1,
      );
      expect(exhausted, isNull);
    });

    test('non-retryable failures never retry', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      expect(
        session.retryDelay(
          StreamFailure(kind: StreamFailureKind.forbidden, providerId: 'p1'),
          10,
        ),
        isNull,
      );
    });

    test('near-expiry extension sources resolve with needsUrlRefresh', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final now = DateTime.utc(2026, 1, 1, 12);
      final stale = StreamDescriptor(
        id: 'stale',
        providerId: 'p1',
        kind: StreamSourceKind.extensionStream,
        uri: 'https://example.test/stale',
        expiresAt: now.add(const Duration(minutes: 2)), // inside lead time
        validFrom: now.subtract(const Duration(minutes: 30)),
      );
      final outcome = session.resolve([stale], now: now);
      expect(outcome.resolved?.id, 'stale');
      expect(outcome.needsUrlRefresh, isTrue);
      expect(session.state.phase, StreamPhase.refreshingUrl);
    });

    test('proceedWithoutRefresh moves a refreshing session to preflighting', () {
      final health = ProviderHealthRegistry();
      final log = EngineEventLog();
      final session = StreamingSessionController(
        resolver: StreamSourceResolver(health: health),
        health: health,
        log: log,
      );
      final now = DateTime.utc(2026, 1, 1, 12);
      final stale = StreamDescriptor(
        id: 'stale',
        providerId: 'p1',
        kind: StreamSourceKind.extensionStream,
        uri: 'https://example.test/stale',
        expiresAt: now.add(const Duration(minutes: 2)),
        validFrom: now.subtract(const Duration(minutes: 30)),
      );
      session.resolve([stale], now: now);
      expect(session.state.phase, StreamPhase.refreshingUrl);
      session.proceedWithoutRefresh(stale);
      expect(session.state.phase, StreamPhase.preflighting);
      expect(session.state.active?.id, 'stale');
    });
  });

  group('StreamUrlRefreshPolicy', () {
    test('refreshes extension sources near expiry', () {
      const policy = StreamUrlRefreshPolicy();
      final now = DateTime.utc(2026, 1, 1, 12);
      final descriptor = StreamDescriptor(
        id: 'x',
        providerId: 'p',
        kind: StreamSourceKind.extensionStream,
        uri: 'https://example.test/x',
        expiresAt: now.add(const Duration(minutes: 4)), // inside 5m lead time
        validFrom: now.subtract(const Duration(minutes: 50)),
      );
      expect(policy.shouldRefresh(descriptor, now: now), isTrue);
    });

    test('never refreshes plain HTTP preview sources', () {
      const policy = StreamUrlRefreshPolicy();
      final now = DateTime.utc(2026, 1, 1, 12);
      final descriptor = StreamDescriptor(
        id: 'x',
        providerId: 'preview',
        kind: StreamSourceKind.httpStream,
        uri: 'https://example.test/x',
        expiresAt: now.subtract(const Duration(seconds: 1)),
        validFrom: now.subtract(const Duration(hours: 1)),
      );
      expect(policy.shouldRefresh(descriptor, now: now), isFalse);
    });

    test('handles a missing validFrom without crashing', () {
      const policy = StreamUrlRefreshPolicy();
      final now = DateTime.utc(2026, 1, 1, 12);
      final descriptor = StreamDescriptor(
        id: 'x',
        providerId: 'p',
        kind: StreamSourceKind.extensionStream,
        uri: 'https://example.test/x',
        expiresAt: now.add(const Duration(minutes: 1)),
      );
      expect(policy.shouldRefresh(descriptor, now: now), isTrue);
    });
  });

  group('SmartPlayEngine', () {
    const engine = SmartPlayEngine();

    SmartPlayInput input({
      String? localPath,
      List<StreamDescriptor> candidates = const [],
      bool downloadAvailable = false,
      NetworkProfile network = NetworkProfile.wifi,
      PlaybackModePreference mode = PlaybackModePreference.smart,
      bool streamingEnabled = true,
    }) => SmartPlayInput(
      trackId: 't1',
      title: 'Track',
      artist: 'Artist',
      localPath: localPath,
      streamCandidates: candidates,
      downloadAvailable: downloadAvailable,
      networkProfile: network,
      modePreference: mode,
      streamingEnabled: streamingEnabled,
    );

    StreamDescriptor stream(String id, [AudioQualityLevel quality = AudioQualityLevel.high]) =>
        StreamDescriptor(
          id: id,
          providerId: 'deezer',
          kind: StreamSourceKind.httpStream,
          uri: 'https://example.test/$id',
          quality: quality,
        );

    test('downloaded file plays locally first', () {
      final decision = engine.decide(input(localPath: '/music/a.flac'));
      expect(decision.mode, SmartPlayMode.local);
      expect(decision.summary, 'Local playback');
    });

    test('no local file + candidate streams', () {
      final decision = engine.decide(input(candidates: [stream('a')]));
      expect(decision.mode, SmartPlayMode.stream);
      expect(decision.source?.providerId, 'deezer');
    });

    test('offline with a local copy falls back to local', () {
      final decision = engine.decide(
        input(localPath: '/music/a.flac', candidates: [stream('a')], network: NetworkProfile.offline),
      );
      expect(decision.mode, SmartPlayMode.local);
    });

    test('offline without local copy is unavailable', () {
      final decision = engine.decide(
        input(candidates: [stream('a')], network: NetworkProfile.offline),
      );
      expect(decision.mode, SmartPlayMode.unavailable);
    });

    test('no sources + download available → download & play', () {
      final decision = engine.decide(input(downloadAvailable: true));
      expect(decision.mode, SmartPlayMode.downloadAndPlay);
    });

    test('stream-only mode ignores local file when candidate exists', () {
      final decision = engine.decide(
        input(
          localPath: '/music/a.flac',
          candidates: [stream('a')],
          mode: PlaybackModePreference.stream,
        ),
      );
      expect(decision.mode, SmartPlayMode.stream);
    });

    test('local-only mode rejects streaming', () {
      final decision = engine.decide(
        input(candidates: [stream('a')], mode: PlaybackModePreference.localOnly),
      );
      expect(decision.mode, SmartPlayMode.unavailable);
    });

    test('unavailable decisions carry a human-readable reason', () {
      final decision = engine.decide(
        input(candidates: [stream('a')], network: NetworkProfile.offline),
      );
      expect(decision.mode, SmartPlayMode.unavailable);
      expect(decision.reason, isNotNull);
      expect(decision.reason, isNotEmpty);
      expect(decision.summary, contains(decision.reason!));
      expect(decision.toJson()['reason'], decision.reason);
    });

    test('playable decisions have no reason', () {
      final decision = engine.decide(input(localPath: '/music/a.flac'));
      expect(decision.mode, SmartPlayMode.local);
      expect(decision.reason, isNull);
      expect(decision.summary, 'Local playback');
      expect(decision.toJson().containsKey('reason'), isFalse);
    });
  });

  group('PlaybackSavepoint', () {
    SessionQueueEntry entry(String id, {String? localPath, String? streamUrl}) =>
        SessionQueueEntry(
          id: id,
          trackId: id,
          providerId: 'p',
          title: 'Title',
          artist: 'Artist',
          localPath: localPath,
          streamUrl: streamUrl,
        );

    test('json roundtrip preserves queue and transport', () {
      final savepoint = PlaybackSavepoint(
        entries: [entry('a', localPath: '/a.flac'), entry('b', streamUrl: 'https://x/b')],
        currentIndex: 1,
        positionMs: 4200,
        shuffle: SessionShuffleMode.on,
        repeat: SessionRepeatMode.one,
        playbackMode: 'stream',
        volume: 0.8,
        playbackRate: 1.5,
        balance: -0.2,
      );
      final restored = PlaybackSavepoint.fromJson(savepoint.toJson());
      expect(restored.entries.length, 2);
      expect(restored.positionMs, 4200);
      expect(restored.repeat, SessionRepeatMode.one);
      expect(restored.playbackMode, 'stream');
      expect(restored.volume, 0.8);
      expect(restored.balance, -0.2);
    });

    test('sanitize drops dead entries and normalizes the index', () {
      final savepoint = PlaybackSavepoint(
        entries: [entry('dead', streamUrl: 'https://x/dead')],
        currentIndex: 0,
      );
      // Stream URLs older than the max age are treated as dead.
      final sanitized = savepoint.sanitize(
        now: DateTime.now().add(const Duration(hours: 7)),
      );
      expect(sanitized.isEmpty, isTrue);
      expect(sanitized.currentIndex, 0);
    });
  });

  group('QueuePlanner', () {
    test('shuffle order is reproducible from a seed', () {
      final a = QueuePlanner.shuffledIndices(10, seed: 42);
      final b = QueuePlanner.shuffledIndices(10, seed: 42);
      expect(a, b);
      expect(a.toSet(), {0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
    });

    test('next stops at the end unless repeat-all', () {
      expect(
        QueuePlanner.nextIndex(
          current: 4,
          length: 5,
          repeat: SessionRepeatMode.none,
          shuffle: false,
        ),
        -1,
      );
      expect(
        QueuePlanner.nextIndex(
          current: 4,
          length: 5,
          repeat: SessionRepeatMode.all,
          shuffle: false,
        ),
        0,
      );
    });
  });

  group('ListeningStats', () {
    test('accumulates plays, skips and listened time', () {
      final stats = ListeningStats.empty()
          .recordPlay()
          .recordSkip()
          .recordListen(const Duration(seconds: 90))
          .recordListen(const Duration(seconds: 30));
      expect(stats.plays, 1);
      expect(stats.skips, 1);
      expect(stats.listenedMs, 120000);
      expect(stats.listenedTodayMs, 120000);
    });

    test('negative elapsed never regresses', () {
      final stats = ListeningStats.empty().recordListen(const Duration(seconds: 10));
      final after = stats.recordListen(const Duration(seconds: -5));
      expect(after.listenedMs, stats.listenedMs);
    });

    test('streak counts consecutive play days', () {
      final today = DateTime.now().toUtc();
      final stats = ListeningStats.empty()
          .recordPlay(at: today)
          .recordPlay(at: today.subtract(const Duration(days: 1)));
      expect(stats.streakDays, greaterThanOrEqualTo(2));
    });

    test('json roundtrip', () {
      final stats = ListeningStats.empty()
          .recordPlay()
          .recordListen(const Duration(seconds: 42));
      final restored = ListeningStats.fromJson(stats.toJson());
      expect(restored.plays, stats.plays);
      expect(restored.listenedMs, stats.listenedMs);
      expect(restored.streakDays, stats.streakDays);
    });

    test('tracks per-track plays and recent/most played ordering', () {
      final identityA = const TrackPlayIdentity(
        trackId: 'a',
        title: 'Alpha',
        artist: 'Artist',
      );
      final identityB = const TrackPlayIdentity(
        trackId: 'b',
        title: 'Beta',
        artist: 'Artist',
      );
      final at = DateTime.utc(2026, 9, 1, 12);
      final stats = ListeningStats.empty()
          .recordTrackPlay(identityA, at: at)
          .recordTrackPlay(identityB, at: at.add(const Duration(seconds: 5)))
          .recordTrackPlay(identityA, at: at.add(const Duration(seconds: 10)))
          .recordTrackListen(
            identityA,
            const Duration(minutes: 3),
            at: at.add(const Duration(seconds: 12)),
          );
      expect(stats.trackStats['a']?.playCount, 2);
      expect(stats.trackStats['b']?.playCount, 1);
      expect(stats.recentTracks.first.trackId, 'a');
      expect(stats.mostPlayedTracks.first.trackId, 'a');
      expect(stats.mostPlayedTracks.first.listenedMs, 180000);
    });

    test('track stats json roundtrip', () {
      final identity = const TrackPlayIdentity(
        trackId: 'a',
        title: 'Alpha',
        artist: 'Artist',
        album: 'Album',
      );
      final stats = ListeningStats.empty().recordTrackPlay(identity);
      final restored = ListeningStats.fromJson(stats.toJson());
      expect(restored.trackStats['a']?.playCount, 1);
      expect(restored.trackStats['a']?.title, 'Alpha');
    });
  });

  group('BandwidthMonitor', () {
    test('computes effective throughput from preflight metadata', () {
      final monitor = BandwidthMonitor();
      monitor.recordPreflight(
        latencyMs: 100,
        contentLengthBytes: 128000,
        providerId: 'preview',
      );
      // 128000 bytes over 0.1s = 1,280,000 B/s ≈ 10.24 Mbps.
      expect(monitor.latestBytesPerSecond, 1280000);
      expect(monitor.smoothedBytesPerSecond, 1280000);
      expect(formatBandwidth(monitor.smoothedBytesPerSecond), '10.2 Mbps');
    });

    test('median smooths a single noisy sample', () {
      final monitor = BandwidthMonitor();
      monitor.recordPreflight(latencyMs: 200, contentLengthBytes: 2000);
      monitor.recordPreflight(latencyMs: 200, contentLengthBytes: 4000);
      monitor.recordPreflight(latencyMs: 200, contentLengthBytes: 6000);
      expect(monitor.smoothedBytesPerSecond, 20000);
    });
  });

  group('StreamPreloader', () {
    test('plans and validates without duplicate work', () async {
      final log = EngineEventLog();
      final preloader = StreamPreloader(
        validator: _OkValidator(),
        log: log,
      );
      await preloader.plan(
        ['t1'],
        window: 1,
        resolver: (id) => StreamDescriptor(
          id: '$id-source',
          providerId: 'p',
          kind: StreamSourceKind.httpStream,
          uri: 'https://example.test/$id',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(preloader.jobFor('t1')?.state, PreloadJobState.ready);
      expect(preloader.isReady('t1'), isTrue);
    });

    test('keeps the job registry bounded', () async {
      final log = EngineEventLog();
      final preloader = StreamPreloader(
        validator: _OkValidator(),
        log: log,
      );
      for (var i = 0; i < 300; i++) {
        await preloader.plan(
          ['track-$i'],
          window: 1,
          resolver: (id) => StreamDescriptor(
            id: id,
            providerId: 'p',
            kind: StreamSourceKind.httpStream,
            uri: 'https://example.test/$id',
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      // Completed jobs must be pruned; the registry stays bounded.
      expect(preloader.jobCount, lessThanOrEqualTo(130));
    });
  });
}

class _OkValidator implements StreamPreflightValidator {
  @override
  Future<StreamPreflightResult> validate(StreamDescriptor source) async =>
      StreamPreflightResult.success(latencyMs: 12, contentType: 'audio/mpeg');
}
