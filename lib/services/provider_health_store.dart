/// Local persistence for streaming provider health metrics (Phase 3).
///
/// What survives a restart:
///   * per-provider success/failure counts,
///   * last observed latency, last success/failure timestamps, last error.
///
/// What deliberately does *not* survive:
///   * circuit-breaker cooldowns — [StreamProviderHealthRegistry.mergeRestored]
///     drops them so a provider that recovered while the app was closed is
///     immediately usable in the next session.
///
/// Writes are debounced (metrics change on every resolution attempt) and
/// best-effort: persistence can never break playback, so every failure is
/// logged and swallowed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('ProviderHealthStore');

/// Minimal async string key-value port. [SharedPreferences] in production;
/// an in-memory fake in tests.
abstract class ProviderHealthKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class _SharedPreferencesStore implements ProviderHealthKeyValueStore {
  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }
}

/// Owns the lifecycle: restore on [attach], debounced saves on every registry
/// mutation, final [flush]/[dispose] on teardown.
class ProviderHealthStore {
  ProviderHealthStore({
    required ProviderHealthKeyValueStore store,
    this.persistDebounce = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _store = store,
       _now = now ?? DateTime.now;

  static const String prefsKey = 'spotiflac.provider_health_metrics.v1';

  /// Key written by the short-lived 5.0.0 (SpotiMusic) builds. Read once as a
  /// fallback when the canonical key is empty; never written.
  static const String legacyPrefsKey = 'spotimusic.provider_health_metrics.v1';
  static const int schemaVersion = 1;

  /// Upper bound for the persisted payload. Health rows are tiny (≈200 bytes
  /// each, 8 providers); the cap exists so a corrupt runaway can never grow
  /// unbounded in SharedPreferences.
  static const int maxPayloadBytes = 32 * 1024;

  final ProviderHealthKeyValueStore _store;
  final Duration persistDebounce;
  final DateTime Function() _now;

  StreamProviderHealthRegistry? _registry;
  void Function()? _removeListener;
  Timer? _pendingSave;
  bool _disposed = false;

  /// Convenience entry point used by the app provider graph.
  static ProviderHealthStore attachTo(
    StreamProviderHealthRegistry registry, {
    Duration persistDebounce = const Duration(seconds: 3),
  }) {
    final store = ProviderHealthStore(
      store: _SharedPreferencesStore(),
      persistDebounce: persistDebounce,
    );
    unawaited(store.attach(registry));
    return store;
  }

  /// Restores the persisted snapshot into [registry] and subscribes to
  /// changes. Safe to call more than once; the second call is a no-op.
  Future<void> attach(StreamProviderHealthRegistry registry) async {
    if (_disposed || _registry != null) return;
    _registry = registry;

    var restored = 0;
    try {
      var raw = await _store.read(prefsKey);
      if (raw == null || raw.isEmpty) {
        raw = await _store.read(legacyPrefsKey);
      }
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          if (decoded['schema'] != schemaVersion) {
            _log.i(
              'discarding provider health snapshot with unknown schema '
              '${decoded['schema']} (expected $schemaVersion)',
            );
          } else {
            restored = registry.mergeRestored(decoded);
          }
        }
      }
    } on FormatException catch (e) {
      _log.w('corrupt provider health snapshot discarded: $e');
    } catch (e) {
      _log.w('provider health restore failed: $e');
    }
    if (restored > 0) {
      _log.d('restored metrics for $restored provider(s)');
    }

    _removeListener = registry.addListener(_schedulePersist);
  }

  void _schedulePersist() {
    if (_disposed || _registry == null) return;
    _pendingSave?.cancel();
    _pendingSave = Timer(persistDebounce, () => unawaited(flush()));
  }

  /// Writes the current snapshot immediately (also runs when the debounced
  /// timer fires). Failures are logged, never thrown.
  Future<void> flush() async {
    _pendingSave?.cancel();
    _pendingSave = null;
    await _writeSnapshot();
  }

  Future<void> _writeSnapshot() async {
    final registry = _registry;
    if (registry == null) return;

    final payload = jsonEncode(<String, dynamic>{
      'schema': schemaVersion,
      'saved_at': _now().toUtc().toIso8601String(),
      ...registry.toJson(),
    });
    if (payload.length > maxPayloadBytes) {
      // Defensive: never persist a runaway snapshot.
      _log.w(
        'provider health snapshot exceeds '
        '${maxPayloadBytes}B (${payload.length}B); skipping persist',
      );
      return;
    }
    try {
      await _store.write(prefsKey, payload);
    } catch (e) {
      _log.w('provider health persist failed: $e');
    }
  }

  /// Detaches from the registry and persists one final snapshot.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _removeListener?.call();
    _removeListener = null;
    _pendingSave?.cancel();
    _pendingSave = null;
    await _writeSnapshot();
    _registry = null;
  }
}
