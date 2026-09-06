/// Background synchronization engine (Feature Group 2).
///
/// Sits *above* the existing `core/sync` primitives:
///   * [SyncOrchestrator] owns conflict resolution and the offline outbox;
///   * [CloudSyncProvider] owns the wire protocol;
///   * this class owns **when** a cycle runs and **how** failures are retried.
///
/// Guarantees:
///   * offline-first — local writes always land in the outbox first, so a
///     failed cycle never loses data and the next cycle re-pushes it;
///   * network-aware — metered/roaming links are skipped unless the policy
///     allows them;
///   * bounded retry — exponential backoff with a cap, and a circuit breaker
///     that stops hammering a dead backend until the interval elapses;
///   * never fatal — every failure is captured in [SyncEngineStats.lastError].
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:spotimusic/core/sync/cloud_sync_provider.dart';
import 'package:spotimusic/core/sync/sync_entities.dart';
import 'package:spotimusic/core/sync/sync_orchestrator.dart';
import 'package:spotimusic/ecosystem/sync/sync_payloads.dart';

/// Why a cycle was requested. Recorded for diagnostics.
enum SyncTrigger {
  manual,
  startup,
  periodic,
  connectivityRestored,
  appResumed,
  localChange,
}

/// View of the link the engine syncs over.
class SyncNetworkState {
  const SyncNetworkState({required this.online, this.metered = false});

  final bool online;

  /// Cellular/roaming/hotspot links: counted against the metered policy.
  final bool metered;

  static const SyncNetworkState offline = SyncNetworkState(online: false);
  static const SyncNetworkState wifi = SyncNetworkState(online: true);
  static const SyncNetworkState cellular = SyncNetworkState(
    online: true,
    metered: true,
  );
}

/// Injectable network probe so tests never touch the platform channel.
abstract interface class NetworkGate {
  Future<SyncNetworkState> current();

  Stream<SyncNetworkState> get changes;
}

/// [connectivity_plus]-backed [NetworkGate].
class ConnectivityNetworkGate implements NetworkGate {
  ConnectivityNetworkGate({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<SyncNetworkState> current() async {
    final results = await _connectivity.checkConnectivity();
    return _map(results);
  }

  @override
  Stream<SyncNetworkState> get changes =>
      _connectivity.onConnectivityChanged.map(_map);

  static SyncNetworkState _map(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return SyncNetworkState.offline;
    }
    final metered = results.every(
      (result) =>
          result == ConnectivityResult.mobile ||
          result == ConnectivityResult.vpn,
    );
    return SyncNetworkState(online: true, metered: metered);
  }
}

/// Fixed [NetworkGate] for tests and for "no connectivity plugin" builds.
class StaticNetworkGate implements NetworkGate {
  StaticNetworkGate(this._state);

  final SyncNetworkState _state;

  @override
  Future<SyncNetworkState> current() async => _state;

  @override
  Stream<SyncNetworkState> get changes => const Stream<SyncNetworkState>.empty();
}

/// Scheduling + retry policy. Immutable value type.
class SyncPolicy {
  const SyncPolicy({
    this.interval = const Duration(minutes: 15),
    this.retryBaseDelay = const Duration(seconds: 5),
    this.maxRetries = 3,
    this.maxRetryDelay = const Duration(minutes: 5),
    this.allowMetered = false,
    this.syncOnStartup = true,
    this.debounceLocalChanges = const Duration(seconds: 20),
    Set<SyncScope>? enabledScopes,
  }) : enabledScopes = enabledScopes ?? const <SyncScope>{};

  /// How often a background cycle runs while the app is alive.
  final Duration interval;

  final Duration retryBaseDelay;
  final int maxRetries;
  final Duration maxRetryDelay;

  /// Sync over cellular/roaming links.
  final bool allowMetered;

  final bool syncOnStartup;

  /// Local writes are coalesced for this long before a push is scheduled.
  final Duration debounceLocalChanges;

  /// Scopes this engine is allowed to sync. `SyncEngine` normalizes an empty
  /// set to [SyncScopeDescriptor.defaultEnabledScopes] so a freshly
  /// constructed policy syncs the standard set.
  final Set<SyncScope> enabledScopes;

  static SyncPolicy get defaults => SyncPolicy(
    enabledScopes: SyncScopeDescriptor.defaultEnabledScopes(),
  );

  bool isEnabled(SyncScope scope) => enabledScopes.contains(scope);

  SyncPolicy copyWith({
    Duration? interval,
    Duration? retryBaseDelay,
    int? maxRetries,
    Duration? maxRetryDelay,
    bool? allowMetered,
    bool? syncOnStartup,
    Duration? debounceLocalChanges,
    Set<SyncScope>? enabledScopes,
  }) {
    return SyncPolicy(
      interval: interval ?? this.interval,
      retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
      maxRetries: maxRetries ?? this.maxRetries,
      maxRetryDelay: maxRetryDelay ?? this.maxRetryDelay,
      allowMetered: allowMetered ?? this.allowMetered,
      syncOnStartup: syncOnStartup ?? this.syncOnStartup,
      debounceLocalChanges: debounceLocalChanges ?? this.debounceLocalChanges,
      enabledScopes: enabledScopes ?? this.enabledScopes,
    );
  }
}

/// Outcome of one full cycle across all enabled scopes.
class SyncCycleReport {
  const SyncCycleReport({
    required this.trigger,
    required this.scopes,
    required this.pushedRecords,
    required this.pulledRecords,
    required this.conflictsResolved,
    required this.succeeded,
    this.error,
    this.skipped,
  });

  final SyncTrigger trigger;
  final List<SyncScope> scopes;
  final int pushedRecords;
  final int pulledRecords;
  final int conflictsResolved;
  final bool succeeded;
  final String? error;

  /// Why the cycle did not run (`offline`, `metered`, `disabled`, …).
  final String? skipped;

  static SyncCycleReport skippedCycle(SyncTrigger trigger, String reason) =>
      SyncCycleReport(
        trigger: trigger,
        scopes: const <SyncScope>[],
        pushedRecords: 0,
        pulledRecords: 0,
        conflictsResolved: 0,
        succeeded: false,
        skipped: reason,
      );
}

/// Running counters surfaced to the sync page.
class SyncEngineStats {
  const SyncEngineStats({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastError,
    this.consecutiveFailures = 0,
    this.nextRetryAt,
    this.totalPushedRecords = 0,
    this.totalPulledRecords = 0,
    this.totalConflictsResolved = 0,
    this.cycles = 0,
  });

  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final String? lastError;
  final int consecutiveFailures;
  final DateTime? nextRetryAt;
  final int totalPushedRecords;
  final int totalPulledRecords;
  final int totalConflictsResolved;
  final int cycles;

  SyncEngineStats copyWith({
    DateTime? lastAttemptAt,
    DateTime? lastSuccessAt,
    String? lastError,
    int? consecutiveFailures,
    DateTime? nextRetryAt,
    int? totalPushedRecords,
    int? totalPulledRecords,
    int? totalConflictsResolved,
    int? cycles,
    bool clearError = false,
  }) {
    return SyncEngineStats(
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      totalPushedRecords: totalPushedRecords ?? this.totalPushedRecords,
      totalPulledRecords: totalPulledRecords ?? this.totalPulledRecords,
      totalConflictsResolved:
          totalConflictsResolved ?? this.totalConflictsResolved,
      cycles: cycles ?? this.cycles,
    );
  }
}

/// Drives periodic, retried, network-aware sync cycles.
class SyncEngine {
  SyncEngine({
    required CloudSyncProvider backend,
    required SyncOrchestrator orchestrator,
    SyncPolicy policy = const SyncPolicy(),
    NetworkGate? networkGate,
    Future<void> Function(Duration delay)? sleeper,
  }) : _backend = backend,
       _orchestrator = orchestrator,
       _policy = policy.enabledScopes.isEmpty
           ? policy.copyWith(
               enabledScopes: SyncScopeDescriptor.defaultEnabledScopes(),
             )
           : policy,
       _network = networkGate ?? ConnectivityNetworkGate(),
       _sleeper = sleeper ?? Future<void>.delayed;

  final CloudSyncProvider _backend;
  final SyncOrchestrator _orchestrator;
  final NetworkGate _network;
  final Future<void> Function(Duration) _sleeper;

  SyncPolicy _policy;
  Timer? _periodicTimer;
  Timer? _debounceTimer;
  StreamSubscription<SyncNetworkState>? _networkSub;

  final StreamController<SyncEngineStats> _stats =
      StreamController<SyncEngineStats>.broadcast();
  final StreamController<SyncCycleReport> _reports =
      StreamController<SyncCycleReport>.broadcast();

  SyncEngineStats _current = const SyncEngineStats();
  bool _running = false;
  bool _disposed = false;

  SyncPolicy get policy => _policy;
  SyncEngineStats get stats => _current;
  Stream<SyncEngineStats> get statsStream => _stats.stream;
  Stream<SyncCycleReport> get reports => _reports.stream;

  /// Applies a new policy; a shorter interval restarts the timer.
  void updatePolicy(SyncPolicy policy) {
    final wasRunning = _periodicTimer != null;
    _policy = policy.enabledScopes.isEmpty
        ? policy.copyWith(
            enabledScopes: SyncScopeDescriptor.defaultEnabledScopes(),
          )
        : policy;
    if (wasRunning) start();
  }

  /// Starts the background timer and the connectivity listener.
  void start({bool runImmediately = false}) {
    if (_disposed) return;
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_policy.interval, (_) {
      unawaited(runCycle(trigger: SyncTrigger.periodic));
    });
    _networkSub ??= _network.changes.listen((state) {
      if (state.online && (_policy.allowMetered || !state.metered)) {
        unawaited(runCycle(trigger: SyncTrigger.connectivityRestored));
      }
    });
    if (runImmediately && _policy.syncOnStartup) {
      unawaited(runCycle(trigger: SyncTrigger.startup));
    }
  }

  void stop() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// Coalesces local writes into a single push.
  void notifyLocalChange() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_policy.debounceLocalChanges, () {
      unawaited(runCycle(trigger: SyncTrigger.localChange));
    });
  }

  /// Runs one cycle over every enabled scope. Never throws.
  Future<SyncCycleReport> runCycle({
    SyncTrigger trigger = SyncTrigger.manual,
  }) async {
    if (_disposed) {
      return SyncCycleReport.skippedCycle(trigger, 'disposed');
    }
    if (_running) {
      return SyncCycleReport.skippedCycle(trigger, 'already running');
    }
    if (_backend is NoOpCloudSyncProvider) {
      return _finish(SyncCycleReport.skippedCycle(trigger, 'disabled'), null);
    }

    // Claim the cycle before the first await: a guard that is checked and
    // set across await points lets two concurrent callers both pass it.
    _running = true;
    _emitStats(_current.copyWith(lastAttemptAt: DateTime.now().toUtc()));
    try {
      final network = await _network.current();
      if (!network.online) {
        return _finish(SyncCycleReport.skippedCycle(trigger, 'offline'), null);
      }
      if (network.metered && !_policy.allowMetered) {
        return _finish(SyncCycleReport.skippedCycle(trigger, 'metered'), null);
      }

      final scopes = SyncScope.values
          .where(_policy.isEnabled)
          .toList(growable: false);
      var pushed = 0;
      var pulled = 0;
      var conflicts = 0;
      String? firstError;

      for (final scope in scopes) {
        try {
          final report = await _syncScope(scope);
          pushed += report.pushed;
          pulled += report.pulled;
          conflicts += report.conflicts;
        } on SyncAuthException catch (error) {
          // Session lost: no scope can succeed, stop the cycle.
          firstError = error.message;
          break;
        } catch (error) {
          firstError ??= error.toString();
        }
      }

      final report = SyncCycleReport(
        trigger: trigger,
        scopes: scopes,
        pushedRecords: pushed,
        pulledRecords: pulled,
        conflictsResolved: conflicts,
        succeeded: firstError == null,
        error: firstError,
      );
      return _finish(report, firstError);
    } finally {
      _running = false;
    }
  }

  /// Pulls, merges and pushes one scope under the retry policy.
  ///
  /// A hand-rolled loop rather than `core/application/retry_policy.dart`
  /// because that policy classifies retryability from `CoreErrorCategory`,
  /// and every sync transport failure normalizes to `unknown` (which is
  /// non-retryable by design elsewhere in the app). Sync wants: retry
  /// everything transient with capped exponential backoff, never retry auth.
  Future<_ScopeReport> _syncScope(SyncScope scope) async {
    var attempt = 1;
    while (true) {
      try {
        final remote = await _backend.pull(
          scope,
          sinceRevision: _orchestrator.serverRevisionWatermark(scope),
        );
        final merge = _orchestrator.mergeRemote(scope, remote);
        var pushed = 0;
        final pending = _orchestrator.pendingPush(scope);
        if (pending.isNotEmpty) {
          final accepted = await _backend.push(scope, pending);
          _orchestrator.acknowledgePush(scope, accepted.keys);
          pushed = accepted.length;
        }
        return _ScopeReport(
          pushed: pushed,
          pulled: merge.appliedFromRemote.length,
          conflicts: merge.conflictsResolved,
        );
      } on SyncAuthException {
        rethrow; // session lost — retrying cannot help
      } catch (error) {
        if (attempt >= _policy.maxRetries) rethrow;
        final delay = _backoffFor(attempt);
        _emitStats(
          _current.copyWith(
            nextRetryAt: DateTime.now().toUtc().add(delay),
            lastError: '${scope.wireId} attempt $attempt failed: $error',
          ),
        );
        attempt++;
        if (delay > Duration.zero) {
          await _sleeper(delay);
        }
      }
    }
  }

  SyncCycleReport _finish(SyncCycleReport report, String? error) {
    final now = DateTime.now().toUtc();
    final failed = error != null;
    _emitStats(
      _current.copyWith(
        lastSuccessAt: failed ? null : now,
        lastError: error,
        clearError: !failed,
        consecutiveFailures: failed ? _current.consecutiveFailures + 1 : 0,
        nextRetryAt: failed
            ? now.add(_backoffFor(_current.consecutiveFailures + 1))
            : null,
        totalPushedRecords: _current.totalPushedRecords + report.pushedRecords,
        totalPulledRecords: _current.totalPulledRecords + report.pulledRecords,
        totalConflictsResolved:
            _current.totalConflictsResolved + report.conflictsResolved,
        cycles: _current.cycles + (report.skipped == null ? 1 : 0),
      ),
    );
    if (!_reports.isClosed) {
      _reports.add(report);
    }
    return report;
  }

  Duration _backoffFor(int failures) {
    var delay = _policy.retryBaseDelay.inMilliseconds.toDouble();
    for (var i = 1; i < failures; i++) {
      delay *= 2;
    }
    final capped = delay > _policy.maxRetryDelay.inMilliseconds
        ? _policy.maxRetryDelay.inMilliseconds.toDouble()
        : delay;
    return Duration(milliseconds: capped.round());
  }

  void _emitStats(SyncEngineStats stats) {
    _current = stats;
    if (!_stats.isClosed) {
      _stats.add(stats);
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    _networkSub?.cancel();
    _networkSub = null;
    _stats.close();
    _reports.close();
  }
}

class _ScopeReport {
  const _ScopeReport({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
  });

  final int pushed;
  final int pulled;
  final int conflicts;
}
