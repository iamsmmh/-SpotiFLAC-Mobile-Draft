/// Application service for user accounts (Feature Group 1).
///
/// Owns everything the UI needs and nothing else:
///   * provider registry (Firebase / Supabase / self-hosted / guest),
///   * session lifecycle (restore on boot, refresh, sign-out),
///   * credential handling (always delegated to [AccountTokenStore]),
///   * an [AccountState] stream the Riverpod layer forwards to widgets.
///
/// Failure philosophy matches the rest of the app: a misconfigured or offline
/// backend degrades to guest mode, never to a broken UI.
library;

import 'dart:async';
import 'dart:convert';

import 'package:spotimusic/ecosystem/account/account_models.dart';
import 'package:spotimusic/ecosystem/account/auth_adapters.dart';
import 'package:spotimusic/ecosystem/account/auth_provider.dart';
import 'package:spotimusic/ecosystem/account/token_store.dart';
import 'package:spotimusic/ecosystem/ecosystem_kv.dart';
import 'package:spotimusic/utils/logger.dart';

final _log = AppLogger('AccountService');

const String _activeProviderPrefKey = 'ecosystem.account.active_provider_v1';
const String _selfHostedConfigPrefKey =
    'ecosystem.account.selfhosted_config_v1';
const String _guestOptInPrefKey = 'ecosystem.account.guest_optin_v1';

/// Orchestrates authentication across pluggable backends.
class AccountService {
  AccountService({
    required AccountTokenStore tokenStore,
    KeyValueStore? preferences,
    List<AuthProvider>? providers,
    Duration refreshLead = const Duration(minutes: 2),
  }) : _tokens = tokenStore,
       _prefs =
           preferences ??
            NamespacedKeyValueStore(
              MemoryKeyValueStore(),
              'ecosystem.account.',
            ),
       _refreshLead = refreshLead {
    for (final provider in providers ?? const <AuthProvider>[]) {
      register(provider);
    }
  }

  final AccountTokenStore _tokens;
  final KeyValueStore _prefs;
  final Duration _refreshLead;

  final Map<String, AuthProvider> _providers = <String, AuthProvider>{};
  final StreamController<AccountState> _changes =
      StreamController<AccountState>.broadcast();

  AccountState _state = AccountState.initial;
  AccountSession? _session;
  AuthProvider? _active;
  Future<AccountSession?>? _refreshInFlight;
  bool _restoreAttempted = false;

  // -------------------------------------------------------------------------
  // Introspection
  // -------------------------------------------------------------------------

  AccountState get state => _state;

  /// Current state followed by every subsequent change, so a late listener
  /// (Riverpod `StreamProvider`) still sees a value immediately.
  Stream<AccountState> get changes async* {
    yield _state;
    yield* _changes.stream;
  }

  AccountSession? get session => _session;

  AuthProvider? get activeProvider => _active;

  /// Every registered adapter, in registration order.
  List<AuthProvider> get providers =>
      _providers.values.toList(growable: false);

  /// Adapters that are ready to use right now.
  List<AuthProvider> get configuredProviders =>
      providers.where((provider) => provider.isConfigured).toList(
        growable: false,
      );

  bool get isConfigured => configuredProviders.isNotEmpty;

  /// Registers (or replaces) an adapter. Registration never signs anyone in.
  void register(AuthProvider provider) {
    _providers[provider.id] = provider;
    _emit(
      _state.copyWith(
        availableMethods: _availableMethods(_active),
      ),
    );
  }

  AuthProvider? providerById(String id) => _providers[id];

  // -------------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------------

  /// Silent restore on boot. Safe to call repeatedly; only the first call does
  /// work. Never throws: a failed restore degrades to signed-out/guest.
  Future<void> restoreSession() async {
    if (_restoreAttempted) return;
    _restoreAttempted = true;

    final storedProvider = await _prefs.read(_activeProviderPrefKey);
    final candidates = <String>[
      if (storedProvider != null && storedProvider.isNotEmpty) storedProvider,
      ..._providers.keys,
    ];

    for (final providerId in candidates) {
      final provider = _providers[providerId];
      if (provider == null) continue;
      final credentials = await _tokens.read(providerId);
      if (credentials == null) continue;
      try {
        final session = await provider.restoreSession(credentials);
        await _acceptSession(provider, session, persist: true);
        return;
      } on AuthException catch (error) {
        _log.i('Restore via $providerId failed: ${error.message}');
        // Expired credentials are expected after a long absence: keep the
        // profile so the UI can offer a re-login, but do not keep a session.
        if (error is AuthUnauthorizedException) {
          final mirrored = await _tokens.readMirroredProfile();
          if (mirrored != null) {
            _emit(
              AccountState(
                status: AccountStatus.signedOut,
                user: mirrored,
                backend: provider.kind,
                errorMessage: error.message,
                availableMethods: _availableMethods(provider),
              ),
            );
          }
        }
      } catch (error) {
        _log.w('Restore via $providerId crashed: $error');
      }
    }
  }

  /// Picks the adapter used for subsequent sign-ins.
  Future<void> selectProvider(String providerId) async {
    final provider = _providers[providerId];
    if (provider == null) return;
    _active = provider;
    await _prefs.write(_activeProviderPrefKey, providerId);
    _emit(
      _state.copyWith(
        backend: provider.kind,
        availableMethods: _availableMethods(provider),
      ),
    );
  }

  /// Persists (and applies) a self-hosted endpoint configuration.
  Future<void> configureSelfHosted(SelfHostedAuthConfig config) async {
    final existing = _providers['selfhosted'];
    if (existing is SelfHostedAuthAdapter) {
      existing.config = config;
    } else {
      register(SelfHostedAuthAdapter(config: config));
    }
    await _prefs.write(
      _selfHostedConfigPrefKey,
      jsonEncode(config.toJson()),
    );
    await selectProvider('selfhosted');
  }

  /// Restores a persisted self-hosted configuration (called during bootstrap).
  Future<void> restoreSelfHostedConfiguration() async {
    final raw = await _prefs.read(_selfHostedConfigPrefKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = _decodeJson(raw);
    if (decoded == null) return;
    final config = SelfHostedAuthConfig.fromJson(decoded);
    if (!config.isConfigured) return;
    if (_providers['selfhosted'] == null) {
      register(SelfHostedAuthAdapter(config: config));
    } else if (_providers['selfhosted'] is SelfHostedAuthAdapter) {
      (_providers['selfhosted']! as SelfHostedAuthAdapter).config = config;
    }
  }

  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  }) => _runAuth(
    (provider) => provider.signInWithEmail(email: email, password: password),
  );

  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  }) => _runAuth(
    (provider) => provider.signUpWithEmail(email: email, password: password),
  );

  /// Starts an OAuth flow. Returns the consent URL to open, or null when the
  /// active adapter cannot serve [method] (the UI hides the button instead).
  Future<Uri?> beginOAuth(AuthMethod method, {required String redirectUri}) async {
    final provider = _active;
    if (provider == null) return null;
    return provider.oauthStartUrl(method, redirectUri: redirectUri);
  }

  Future<AccountSession> completeOAuth(AuthMethod method, Uri callback) =>
      _runAuth((provider) => provider.completeOAuth(method, callback));

  /// Local guest mode: no network, no account, everything else works.
  Future<AccountSession> continueAsGuest() async {
    var provider = _providers['anonymous'];
    provider ??= AnonymousAuthAdapter();
    register(provider);
    await _prefs.write(_guestOptInPrefKey, '1');
    return _runAuth(
      (active) => active.signInAnonymously(),
      forcedProvider: provider,
    );
  }

  /// Clears the session and every stored credential for the active provider.
  Future<void> signOut() async {
    final provider = _active;
    final session = _session;
    _session = null;
    if (provider != null) {
      try {
        await provider.signOut(session);
      } catch (_) {
        // Server-side sign-out is best effort.
      }
      await _tokens.clear(provider.id);
    }
    await _tokens.clear('anonymous');
    await _prefs.remove(_guestOptInPrefKey);
    _emit(
      AccountState(
        status: AccountStatus.signedOut,
        backend: provider?.kind ?? AccountBackendKind.none,
        availableMethods: _availableMethods(provider),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// A usable access token, refreshing first when needed. Null in guest mode
  /// or when signed out.
  Future<String?> accessToken() async {
    final session = _session;
    if (session == null) return null;
    final now = DateTime.now().toUtc();
    if (!session.needsRefresh(now, lead: _refreshLead)) {
      return session.accessToken;
    }
    final refreshed = await _refresh();
    return refreshed?.accessToken ?? session.accessToken;
  }

  Future<AccountSession?> _refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    final future = _refreshInternal();
    _refreshInFlight = future;
    return future.whenComplete(() => _refreshInFlight = null);
  }

  Future<AccountSession?> _refreshInternal() async {
    final provider = _active;
    final session = _session;
    if (provider == null || session == null || !session.canRefresh) {
      return null;
    }
    try {
      final refreshed = await provider.refreshSession(session);
      await _acceptSession(provider, refreshed, persist: true);
      return refreshed;
    } on AuthException catch (error) {
      _log.w('Token refresh failed: ${error.message}');
      _emit(
        _state.copyWith(
          status: error is AuthUnauthorizedException
              ? AccountStatus.signedOut
              : AccountStatus.error,
          errorMessage: error.message,
        ),
      );
      return null;
    } catch (error) {
      _log.w('Token refresh crashed: $error');
      return null;
    }
  }

  Future<AccountSession> _runAuth(
    Future<AccountSession> Function(AuthProvider provider) action, {
    AuthProvider? forcedProvider,
  }) async {
    final provider = forcedProvider ?? _active;
    if (provider == null) {
      const error = AuthConfigurationException(
        'no account backend is configured for this build',
      );
      _fail(error);
      throw error;
    }
    _emit(
      _state.copyWith(
        status: AccountStatus.signingIn,
        backend: provider.kind,
        clearError: true,
        availableMethods: _availableMethods(provider),
      ),
    );
    try {
      final session = await action(provider);
      await _acceptSession(provider, session, persist: true);
      return session;
    } on AuthException catch (error) {
      _fail(error, provider: provider);
      rethrow;
    } catch (error) {
      final wrapped = AuthNetworkException(error.toString());
      _fail(wrapped, provider: provider);
      throw wrapped;
    }
  }

  Future<void> _acceptSession(
    AuthProvider provider,
    AccountSession session, {
    required bool persist,
  }) async {
    _active = provider;
    _session = session;
    if (persist) {
      await _tokens.persist(provider.id, session);
      await _prefs.write(_activeProviderPrefKey, provider.id);
    }
    _emit(
      AccountState(
        status: session.user.isGuest
            ? AccountStatus.guest
            : AccountStatus.signedIn,
        user: session.user,
        backend: provider.kind,
        availableMethods: _availableMethods(provider),
        updatedAt: DateTime.now(),
      ),
    );
  }

  void _fail(AuthException error, {AuthProvider? provider}) {
    _emit(
      _state.copyWith(
        status: provider != null && _session != null
            ? _state.status
            : AccountStatus.error,
        errorMessage: error.message,
        backend: provider?.kind ?? _state.backend,
        availableMethods: _availableMethods(provider ?? _active),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Set<AuthMethod> _availableMethods(AuthProvider? provider) {
    if (provider == null) {
      return _providers.containsKey('anonymous')
          ? const <AuthMethod>{AuthMethod.anonymous}
          : const <AuthMethod>{};
    }
    final methods = <AuthMethod>{...provider.supportedMethods};
    if (_providers.containsKey('anonymous')) {
      methods.add(AuthMethod.anonymous);
    }
    return methods;
  }

  void _emit(AccountState next) {
    _state = next;
    if (!_changes.isClosed) {
      _changes.add(next);
    }
  }

  void dispose() {
    _changes.close();
  }

  static Map<String, Object?>? _decodeJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      return null;
    } on FormatException {
      return null;
    }
  }
}
