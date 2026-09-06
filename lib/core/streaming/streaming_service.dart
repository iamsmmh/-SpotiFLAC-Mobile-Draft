/// Streaming service facade (Feature 1).
///
/// Walks registered [StreamProvider]s in priority order, resolves a track
/// to a [StreamSource], narrows manifests through the protocol resolver
/// (HLS variant / DASH representation selection) and validates the result
/// before handing it to playback. Failover is provider-level and
/// protocol-level: every attempt is traced, retries are bounded, and the
/// first *validated* source wins.
///
/// Pure Dart with injected I/O ports (manifest fetcher, validator, clock)
/// so the whole ladder is unit-testable and reusable by both the Smart Play
/// engine path and the hybrid playback manager.
library;

import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/core/streaming/stream_resolver.dart';
import 'package:spotimusic/core/streaming/stream_session.dart';
import 'package:spotimusic/models/track.dart';

/// Result of validating one candidate source.
class StreamValidationOutcome {
  const StreamValidationOutcome({
    required this.source,
    required this.ok,
    this.reason = '',
    this.contentType,
    this.contentLengthBytes,
  });

  final StreamSource source;
  final bool ok;
  final String reason;
  final String? contentType;
  final int? contentLengthBytes;
}

/// Validation port. The production implementation performs a bounded
/// ranged GET (the same policy as the engine's preflight validator).
abstract class StreamSourceValidator {
  Future<StreamValidationOutcome> validate(
    StreamSource source, {
    Map<String, String> extraHeaders = const <String, String>{},
  });
}

/// One traced resolution attempt.
class StreamingAttempt {
  const StreamingAttempt({
    required this.providerId,
    required this.url,
    required this.succeeded,
    this.reason = '',
  });

  final String providerId;
  final String url;
  final bool succeeded;
  final String reason;
}

/// Outcome of [StreamingService.resolveTrack].
class StreamingResolution {
  const StreamingResolution({
    required this.trackId,
    required this.attempts,
    this.source,
    this.session,
  });

  final String trackId;
  final List<StreamingAttempt> attempts;
  final StreamSource? source;
  final StreamSession? session;

  bool get succeeded => source != null;

  String get failureSummary {
    if (attempts.isEmpty) return 'No streaming provider registered';
    return attempts
        .where((attempt) => !attempt.succeeded)
        .map((attempt) => '${attempt.providerId}: ${attempt.reason}')
        .join('; ');
  }
}

/// Configuration for one resolution run.
class StreamingServiceOptions {
  const StreamingServiceOptions({
    this.bandwidthBps,
    this.maxAttemptsPerProvider = 2,
    this.totalAttemptBudget = 8,
    this.preferLossless = true,
    this.allowHls = true,
    this.allowDash = true,
  });

  /// Live bandwidth estimate (bps); null → quality-first ranking.
  final int? bandwidthBps;
  final int maxAttemptsPerProvider;
  final int totalAttemptBudget;
  final bool preferLossless;
  final bool allowHls;
  final bool allowDash;
}

/// The facade. One instance per app; providers register/unregister at
/// runtime (self-hosted servers connecting, extensions installing).
class StreamingService {
  StreamingService({
    required StreamSourceValidator validator,
    StreamProtocolResolver resolver = const StreamProtocolResolver(),
    ManifestFetcher? manifestFetch,
    List<StreamProvider> providers = const <StreamProvider>[],
  }) : _validator = validator,
       _resolver = resolver,
       _manifestFetch = manifestFetch ?? _throwingManifestFetch,
       _providers = <StreamProvider>[...providers];

  final StreamSourceValidator _validator;
  final StreamProtocolResolver _resolver;
  final ManifestFetcher _manifestFetch;
  final List<StreamProvider> _providers;

  /// Providers currently registered, ordered by priority then id.
  List<StreamProvider> get providers {
    final sorted = <StreamProvider>[..._providers]
      ..sort((a, b) {
        final byPriority = a.priority.compareTo(b.priority);
        if (byPriority != 0) return byPriority;
        return a.id.compareTo(b.id);
      });
    return List<StreamProvider>.unmodifiable(sorted);
  }

  void registerProvider(StreamProvider provider) {
    unregisterProvider(provider.id);
    _providers.add(provider);
  }

  void unregisterProvider(String providerId) {
    _providers.removeWhere((provider) => provider.id == providerId);
  }

  /// Resolves [track] to a validated [StreamSource].
  ///
  /// The ladder, per provider (priority order): resolve → protocol-narrow
  /// → validate. Failures fail over to the next provider and then to the
  /// remaining candidates of the same provider, bounded by the options'
  /// attempt budget. A pre-resolved [session] records the phases when
  /// given; one is created otherwise.
  Future<StreamingResolution> resolveTrack(
    Track track, {
    StreamingServiceOptions options = const StreamingServiceOptions(),
    StreamSession? session,
  }) async {
    final activeSession =
        session ??
        StreamSession(trackId: track.id)
          ..beginResolving();
    if (session != null && session.phase == StreamSessionPhase.idle) {
      session.beginResolving();
    }

    final attempts = <StreamingAttempt>[];
    var budget = options.totalAttemptBudget;
    final registered = providers
        .where((provider) => provider.enabled)
        .toList(growable: false);

    for (final provider in registered) {
      if (budget <= 0) break;
      var providerAttempts = 0;
      StreamSource? candidate;
      try {
        candidate = await provider.resolveTrack(track);
      } catch (error) {
        attempts.add(
          StreamingAttempt(
            providerId: provider.id,
            url: '',
            succeeded: false,
            reason: 'resolve error: $error',
          ),
        );
        activeSession.recordRetry('${provider.id} resolve error');
        continue;
      }
      if (candidate == null) {
        attempts.add(
          StreamingAttempt(
            providerId: provider.id,
            url: '',
            succeeded: false,
            reason: 'no source',
          ),
        );
        continue;
      }

      // Protocol-level candidates: the raw source, then (when narrowing
      // rewrites it) the narrowed form. Each gets a validation shot.
      final narrowed = await _resolver.narrow(
        candidate,
        fetch: _manifestFetch,
        bandwidthBps: options.bandwidthBps,
      );
      final chain = narrowed.url == candidate.url
          ? <StreamSource>[candidate]
          : <StreamSource>[narrowed, candidate];

      for (final source in chain) {
        if (budget <= 0 || providerAttempts >= options.maxAttemptsPerProvider) {
          break;
        }
        if (source.isExpired) {
          attempts.add(
            StreamingAttempt(
              providerId: provider.id,
              url: source.url,
              succeeded: false,
              reason: 'url expired',
            ),
          );
          activeSession.recordRetry('${provider.id} expired url');
          providerAttempts += 1;
          budget -= 1;
          continue;
        }
        budget -= 1;
        providerAttempts += 1;
        activeSession.markValidating(source);
        final outcome = await _validator.validate(
          source,
          extraHeaders: source.headers,
        );
        attempts.add(
          StreamingAttempt(
            providerId: provider.id,
            url: source.url,
            succeeded: outcome.ok,
            reason: outcome.ok ? '' : outcome.reason,
          ),
        );
        if (outcome.ok) {
          return StreamingResolution(
            trackId: track.id,
            attempts: attempts,
            source: source,
            session: activeSession,
          );
        }
        activeSession.recordRetry('${provider.id} ${outcome.reason}');
      }
    }

    return StreamingResolution(
      trackId: track.id,
      attempts: attempts,
      source: null,
      session: activeSession,
    );
  }
}

Future<String?> _throwingManifestFetch(Uri uri) {
  throw UnsupportedError(
    'StreamingService was built without a manifest fetcher and cannot '
    'negotiate $uri',
  );
}
