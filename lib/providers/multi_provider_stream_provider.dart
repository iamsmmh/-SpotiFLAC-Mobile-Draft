import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spotiflac_android/services/multi_provider_stream_service.dart';
import 'package:spotiflac_android/services/provider_credentials.dart';
import 'package:spotiflac_android/services/provider_health_store.dart';

/// App-wide [MultiProviderStreamService] instance (YouTube Explode + HTTP are
/// kept for the app lifetime and disposed only with the provider container).
///
/// Credentialed providers (Tidal, Qobuz, Apple, Deezer, Amazon) resolve
/// user-supplied tokens from secure storage at request time — see
/// Settings → Provider accounts.
///
/// Provider health metrics (success/failure counts, latency, last error) are
/// restored from local storage on creation and re-persisted (debounced) on
/// every resolution outcome; cooldowns always reset per session.
final multiProviderStreamServiceProvider =
    Provider<MultiProviderStreamService>((ref) {
      final service = MultiProviderStreamService(
        credentials: SecureStoreStreamCredentials(),
      );
      final healthStore = ProviderHealthStore.attachTo(service.health);
      ref.onDispose(() {
        unawaited(healthStore.dispose());
        service.dispose();
      });
      return service;
    });

/// The currently selected streaming provider chip. Persisted across launches.
class ActiveStreamProviderNotifier extends Notifier<StreamProviderId> {
  static const String _prefsKey = 'spotiflac.active_stream_provider';

  /// Key written by the short-lived 5.0.0 (SpotiMusic) builds. Read once as a
  /// fallback so an in-place upgrade keeps the user's chip; never written.
  static const String _legacyPrefsKey = 'spotimusic.active_stream_provider';

  @override
  StreamProviderId build() {
    // YouTube is always playable without credentials, so it is the safe
    // default. The persisted choice is restored via [load] during eager
    // startup (kept synchronous here so building in tests never spins up an
    // un-awaited SharedPreferences Future).
    return StreamProviderId.youtube;
  }

  Future<void> select(StreamProviderId provider) async {
    state = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, provider.name);
  }

  /// Restores the persisted choice (called during eager startup).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored =
        prefs.getString(_prefsKey) ?? prefs.getString(_legacyPrefsKey);
    final parsed = _parseProvider(stored);
    if (parsed != null) state = parsed;
  }
}

final activeStreamProviderProvider = NotifierProvider<
    ActiveStreamProviderNotifier,
    StreamProviderId>(ActiveStreamProviderNotifier.new);

StreamProviderId? _parseProvider(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  for (final id in StreamProviderId.values) {
    if (id.name == raw) return id;
  }
  return null;
}
