/// Port for cloud account backends (Feature Group 1).
///
/// The app talks **only** to this interface. Firebase, Supabase and
/// self-hosted adapters implement it; new backends plug in by registering
/// another implementation at composition time — no UI or service change.
///
/// Contract for implementations:
///   * never persist credentials themselves: [AccountService] owns that via
///     the platform secure store;
///   * [refreshSession] must be safe to call concurrently (the service
///     serializes refreshes, but an adapter must not corrupt state);
///   * throwing [AuthConfigurationException] means "not configured yet" — the
///     UI surfaces a configuration prompt instead of an error toast.
library;

import 'package:spotiflac_android/ecosystem/account/account_models.dart';
import 'package:spotiflac_android/ecosystem/account/token_store.dart';

/// Base class for every account failure.
class AuthException implements Exception {
  const AuthException(this.message, {this.code});

  final String message;

  /// Backend-specific error code (`INVALID_LOGIN_CREDENTIALS`, …).
  final String? code;

  @override
  String toString() => 'AuthException(${code ?? '-'}): $message';
}

/// The adapter is missing configuration (API key, base URL, …).
class AuthConfigurationException extends AuthException {
  const AuthConfigurationException(super.message) : super(code: 'not_configured');
}

/// Transport-level failure: worth retrying later.
class AuthNetworkException extends AuthException {
  const AuthNetworkException(super.message) : super(code: 'network');
}

/// Credentials were rejected or expired beyond refresh.
class AuthUnauthorizedException extends AuthException {
  const AuthUnauthorizedException(super.message)
    : super(code: 'unauthorized');
}

abstract interface class AuthProvider {
  /// Stable adapter id: `firebase`, `supabase`, `selfhosted`, `anonymous`.
  String get id;

  /// Human label for the account page.
  String get displayName;

  AccountBackendKind get kind;

  /// Entry points this adapter can actually serve right now.
  Set<AuthMethod> get supportedMethods;

  /// False when the adapter still needs configuration (keys, endpoints).
  bool get isConfigured;

  /// Email + password sign-in.
  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  });

  /// Email + password registration. Adapters that cannot register throw
  /// [AuthConfigurationException].
  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  });

  /// Consent URL for [method], or null when the adapter cannot serve it.
  /// The redirect URI must be handled by the app (custom scheme or the
  /// backend's hosted callback that bounces back with the tokens).
  Uri? oauthStartUrl(AuthMethod method, {required String redirectUri});

  /// Exchanges the callback URI (code or implicit tokens) for a session.
  Future<AccountSession> completeOAuth(AuthMethod method, Uri callbackUri);

  /// Local-only guest profile. Always available, never touches the network.
  Future<AccountSession> signInAnonymously();

  /// Rebuilds a session from persisted credentials (silent sign-in on boot).
  Future<AccountSession> restoreSession(StoredCredentials credentials);

  /// Refreshes an expired (or near-expiry) session.
  Future<AccountSession> refreshSession(AccountSession session);

  /// Invalidates server-side tokens. Must never throw.
  Future<void> signOut(AccountSession? session);
}
