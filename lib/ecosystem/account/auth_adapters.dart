/// Concrete [AuthProvider] adapters (Feature Group 1).
///
/// Every adapter is a thin, dependency-free REST client over `package:http`,
/// so a new backend is a configuration change, not an SDK dependency — which
/// also keeps the Android/iOS build free of Google/Supabase native plugins.
///
/// Wire contracts are documented in `docs/API_CONTRACTS.md`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:spotimusic/ecosystem/account/account_models.dart';
import 'package:spotimusic/ecosystem/account/auth_provider.dart';
import 'package:spotimusic/ecosystem/account/token_store.dart';

// ---------------------------------------------------------------------------
// Shared JSON plumbing
// ---------------------------------------------------------------------------

/// Minimal JSON-over-HTTP helper with the error mapping every adapter needs.
class AuthHttp {
  AuthHttp({http.Client? client, this.timeout = const Duration(seconds: 15)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  Future<Map<String, Object?>> postJson(
    Uri uri, {
    Map<String, Object?>? body,
    Map<String, String>? headers,
  }) async {
    final response = await _send(
      _client.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...?headers,
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decode(response);
  }

  /// POSTs a JSON *array* (used by PostgREST batch upserts).
  Future<Object?> postJsonList(
    Uri uri,
    List<Object?> body, {
    Map<String, String>? headers,
  }) async {
    final response = await _send(
      _client.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...?headers,
        },
        body: jsonEncode(body),
      ),
    );
    final status = response.statusCode;
    if (status == 401 || status == 403) {
      throw AuthUnauthorizedException(AuthHttp._errorMessage(response.body));
    }
    if (status < 200 || status >= 300) {
      throw AuthNetworkException(AuthHttp._errorMessage(response.body));
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, Object?>> postForm(
    Uri uri, {
    Map<String, String>? body,
    Map<String, String>? headers,
  }) async {
    final response = await _send(
      _client.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
          ...?headers,
        },
        body: body,
      ),
    );
    return _decode(response);
  }

  Future<Map<String, Object?>> getJson(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final response = await _send(
      _client.get(
        uri,
        headers: <String, String>{'Accept': 'application/json', ...?headers},
      ),
    );
    return _decode(response);
  }

  Future<http.Response> _send(Future<http.Response> request) async {
    try {
      return await request.timeout(timeout);
    } on AuthException {
      rethrow;
    } catch (error) {
      throw AuthNetworkException('network request failed: $error');
    }
  }

  Map<String, Object?> _decode(http.Response response) {
    final status = response.statusCode;
    if (status == 401 || status == 403) {
      throw AuthUnauthorizedException(_errorMessage(response.body));
    }
    if (status < 200 || status >= 300) {
      throw AuthNetworkException(_errorMessage(response.body));
    }
    if (response.body.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      return const <String, Object?>{};
    } on FormatException {
      throw AuthNetworkException('malformed response from account backend');
    }
  }

  static String _errorMessage(String body) {
    if (body.isEmpty) return 'account backend rejected the request';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
        if (error != null) return error.toString();
        final message = decoded['message'] ?? decoded['error_description'];
        if (message != null) return message.toString();
        final msg = decoded['msg'];
        if (msg != null) return msg.toString();
      }
    } on FormatException {
      // Not JSON: fall through to the raw body.
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

String _str(Map<String, Object?> json, String key, [String fallback = '']) {
  final value = json[key];
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

int? _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _expiresFrom(Map<String, Object?> json, List<String> keys) {
  for (final key in keys) {
    final seconds = _int(json, key);
    if (seconds != null && seconds > 0) {
      return DateTime.now().toUtc().add(Duration(seconds: seconds));
    }
  }
  return null;
}

/// Normalizes the three wire shapes we accept for a user object into a
/// single [AccountUser]. Shape variants:
///   `{user: {...}}`, `{...}` (flat), or Firebase's flat `localId`/`email`.
AccountUser _userFrom(
  Map<String, Object?> json,
  String providerId, {
  bool isGuest = false,
}) {
  final nested = json['user'];
  final source = nested is Map
      ? Map<String, Object?>.from(nested)
      : json;
  final id =
      _str(source, 'id').isNotEmpty
          ? _str(source, 'id')
          : (_str(source, 'localId').isNotEmpty
                ? _str(source, 'localId')
                : _str(source, 'sub'));
  return AccountUser(
    id: id,
    providerId: providerId,
    email: _str(source, 'email'),
    displayName: _nullIfEmpty(
      _str(source, 'displayName').isNotEmpty
          ? _str(source, 'displayName')
          : _str(source, 'name'),
    ),
    avatarUrl: _nullIfEmpty(
      _str(source, 'avatarUrl').isNotEmpty
          ? _str(source, 'avatarUrl')
          : _str(source, 'photoUrl'),
    ),
    isGuest: isGuest,
    emailVerified: source['emailVerified'] == true || source['email_verified'] == true,
  );
}

String? _nullIfEmpty(String value) => value.isEmpty ? null : value;

// ---------------------------------------------------------------------------
// Anonymous / guest
// ---------------------------------------------------------------------------

/// Local-only guest profile: no network, no backend, full app functionality.
///
/// Always registered as the fallback provider so "continue as guest" works on
/// a freshly installed app with zero configuration.
class AnonymousAuthAdapter implements AuthProvider {
  AnonymousAuthAdapter({String? guestId, this.namespace = 'guest'})
    : _guestId = guestId ?? _newGuestId();

  static const int _guestIdLength = 21;

  final String _guestId;
  final String namespace;

  static String _newGuestId() {
    final random = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final buffer = StringBuffer();
    for (var i = 0; i < _guestIdLength; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  @override
  String get id => 'anonymous';

  @override
  String get displayName => 'Guest (on-device)';

  @override
  AccountBackendKind get kind => AccountBackendKind.anonymous;

  @override
  Set<AuthMethod> get supportedMethods => const <AuthMethod>{AuthMethod.anonymous};

  @override
  bool get isConfigured => true;

  AccountSession _session() => AccountSession(
    user: AccountUser(
      id: '$namespace:$_guestId',
      providerId: id,
      displayName: 'Guest',
      isGuest: true,
    ),
    issuedAt: DateTime.now().toUtc(),
  );

  @override
  Future<AccountSession> signInAnonymously() async => _session();

  @override
  Future<AccountSession> restoreSession(StoredCredentials credentials) async {
    final user = credentials.user;
    return AccountSession(
      user: user.copyWith(isGuest: true, providerId: id),
      issuedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<AccountSession> refreshSession(AccountSession session) async => session;

  @override
  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  }) {
    throw const AuthConfigurationException(
      'guest mode has no email sign-in; configure a cloud backend first',
    );
  }

  @override
  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  }) {
    throw const AuthConfigurationException(
      'guest mode has no email sign-up; configure a cloud backend first',
    );
  }

  @override
  Uri? oauthStartUrl(AuthMethod method, {required String redirectUri}) => null;

  @override
  Future<AccountSession> completeOAuth(AuthMethod method, Uri callbackUri) {
    throw const AuthConfigurationException(
      'guest mode has no OAuth; configure a cloud backend first',
    );
  }

  @override
  Future<void> signOut(AccountSession? session) async {}
}

// ---------------------------------------------------------------------------
// Firebase (Identity Toolkit REST)
// ---------------------------------------------------------------------------

/// Firebase Authentication over the public REST API.
///
/// Needs only the web API key — no `firebase_core`, no `google-services.json`,
/// no native SDK. Google/Apple go through `accounts:signInWithIdp` with the
/// ID token the OAuth browser flow returns.
class FirebaseAuthAdapter implements AuthProvider {
  FirebaseAuthAdapter({
    required String apiKey,
    AuthHttp? httpClient,
    this.googleClientId = '',
    this.appleClientId = '',
  }) : _apiKey = apiKey.trim(),
       _http = httpClient ?? AuthHttp();

  static const String _identityBase =
      'https://identitytoolkit.googleapis.com/v1';
  static const String _secureTokenBase = 'https://securetoken.googleapis.com/v1';

  final AuthHttp _http;
  final String _apiKey;

  /// Google OAuth web client used to mint the ID token that
  /// `accounts:signInWithIdp` exchanges. Without it the Google button stays
  /// hidden (the adapter reports an empty method set for it).
  final String googleClientId;

  /// Apple "Services ID" for the web OAuth flow (iOS may later use the native
  /// ASAuthorizationController instead; the port stays the same).
  final String appleClientId;

  @override
  String get id => 'firebase';

  @override
  String get displayName => 'Firebase';

  @override
  AccountBackendKind get kind => AccountBackendKind.firebase;

  @override
  Set<AuthMethod> get supportedMethods => <AuthMethod>{
    if (_apiKey.isNotEmpty) AuthMethod.email,
    if (googleClientId.isNotEmpty) AuthMethod.google,
    if (appleClientId.isNotEmpty) AuthMethod.apple,
  };

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  void _assertConfigured() {
    if (!isConfigured) {
      throw const AuthConfigurationException(
        'Firebase adapter needs a web API key',
      );
    }
  }

  Uri _endpoint(String path) => Uri.parse('$_identityBase/$path?key=$_apiKey');

  @override
  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _endpoint('accounts:signInWithPassword'),
      body: <String, Object?>{
        'email': email,
        'password': password,
        'returnSecureToken': true,
      },
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _endpoint('accounts:signUp'),
      body: <String, Object?>{
        'email': email,
        'password': password,
        'returnSecureToken': true,
      },
    );
    return _sessionFrom(json);
  }

  @override
  Uri? oauthStartUrl(AuthMethod method, {required String redirectUri}) {
    // Firebase has no first-party consent URL: the app obtains a Google/Apple
    // ID token through a standard OAuth flow (implicit `id_token` for Google,
    // `form_post` code+id_token for Apple) and posts it to
    // `accounts:signInWithIdp`.
    switch (method) {
      case AuthMethod.google:
        if (googleClientId.isEmpty) return null;
        return Uri.parse('https://accounts.google.com/o/oauth2/v2/auth').replace(
          queryParameters: <String, String>{
            'client_id': googleClientId,
            'redirect_uri': redirectUri,
            'response_type': 'id_token',
            'scope': 'openid email profile',
            'nonce': _nonce(),
          },
        );
      case AuthMethod.apple:
        if (appleClientId.isEmpty) return null;
        return Uri.parse('https://appleid.apple.com/auth/authorize').replace(
          queryParameters: <String, String>{
            'client_id': appleClientId,
            'redirect_uri': redirectUri,
            'response_type': 'code id_token',
            'scope': 'name email',
            'response_mode': 'form_post',
          },
        );
      case AuthMethod.email:
      case AuthMethod.anonymous:
        return null;
    }
  }

  static String _nonce() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  @override
  Future<AccountSession> completeOAuth(AuthMethod method, Uri callbackUri) async {
    _assertConfigured();
    final provider = _providerIdFor(method);
    if (provider == null) {
      throw AuthConfigurationException('Firebase cannot serve ${method.name}');
    }
    final token = _extractToken(callbackUri);
    if (token == null || token.isEmpty) {
      throw const AuthUnauthorizedException(
        'OAuth callback carried no id_token',
      );
    }
    final json = await _http.postJson(
      _endpoint('accounts:signInWithIdp'),
      body: <String, Object?>{
        'postBody': 'id_token=$token&providerId=$provider',
        'requestUri': 'http://localhost',
        'returnSecureToken': true,
      },
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signInAnonymously() async {
    _assertConfigured();
    final json = await _http.postJson(_endpoint('accounts:signUp'));
    return _sessionFrom(json, isGuest: true);
  }

  @override
  Future<AccountSession> restoreSession(StoredCredentials credentials) async {
    if (!credentials.hasAnyToken) {
      throw const AuthUnauthorizedException('no stored Firebase credentials');
    }
    if (credentials.accessToken != null && credentials.accessToken!.isNotEmpty) {
      final session = credentials.toSession();
      if (!session.isExpired(DateTime.now())) return session;
    }
    final refresh = credentials.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('Firebase refresh token missing');
    }
    return refreshSession(credentials.toSession());
  }

  @override
  Future<AccountSession> refreshSession(AccountSession session) async {
    final refresh = session.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('Firebase session is not refreshable');
    }
    final json = await _http.postForm(
      Uri.parse('$_secureTokenBase/token?key=$_apiKey'),
      body: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      },
    );
    // The secure-token endpoint uses different field names (id_token,
    // refresh_token, user_id) than the identity endpoint.
    final expires = _expiresFrom(json, const <String>['expires_in']);
    return AccountSession(
      user: AccountUser(
        id: _str(json, 'user_id', session.user.id),
        providerId: id,
        email: session.user.email,
        displayName: session.user.displayName,
        avatarUrl: session.user.avatarUrl,
      ),
      accessToken: _str(json, 'id_token', session.accessToken ?? ''),
      refreshToken: _str(json, 'refresh_token', refresh),
      expiresAt: expires,
      issuedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> signOut(AccountSession? session) async {
    // Firebase ID tokens are stateless JWTs; revocation is server-side.
  }

  AccountSession _sessionFrom(Map<String, Object?> json, {bool isGuest = false}) {
    return AccountSession(
      user: _userFrom(json, id, isGuest: isGuest),
      accessToken: _nullIfEmpty(_str(json, 'idToken')),
      refreshToken: _nullIfEmpty(_str(json, 'refreshToken')),
      expiresAt: _expiresFrom(json, const <String>['expiresIn']),
      issuedAt: DateTime.now().toUtc(),
    );
  }

  static String? _providerIdFor(AuthMethod method) {
    switch (method) {
      case AuthMethod.google:
        return 'google.com';
      case AuthMethod.apple:
        return 'apple.com';
      case AuthMethod.email:
      case AuthMethod.anonymous:
        return null;
    }
  }

  static String? _extractToken(Uri uri) {
    final fragment = uri.fragment;
    final source =
        fragment.isNotEmpty && fragment.contains('=')
            ? Uri.splitQueryString(fragment)
            : uri.queryParameters;
    return source['id_token'] ?? source['access_token'] ?? source['code'];
  }
}

// ---------------------------------------------------------------------------
// Supabase (GoTrue REST)
// ---------------------------------------------------------------------------

/// Supabase Auth over GoTrue's REST endpoints.
class SupabaseAuthAdapter implements AuthProvider {
  SupabaseAuthAdapter({
    required String baseUrl,
    required this.anonKey,
    AuthHttp? httpClient,
  }) : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       _http = httpClient ?? AuthHttp();

  final AuthHttp _http;
  final String _baseUrl;
  final String anonKey;

  @override
  String get id => 'supabase';

  @override
  String get displayName => 'Supabase';

  @override
  AccountBackendKind get kind => AccountBackendKind.supabase;

  @override
  Set<AuthMethod> get supportedMethods => const <AuthMethod>{
    AuthMethod.email,
    AuthMethod.google,
    AuthMethod.apple,
  };

  @override
  bool get isConfigured => _baseUrl.isNotEmpty && anonKey.isNotEmpty;

  void _assertConfigured() {
    if (!isConfigured) {
      throw const AuthConfigurationException(
        'Supabase adapter needs a project URL and anon key',
      );
    }
  }

  Map<String, String> get _headers => <String, String>{
    'apikey': anonKey,
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl$path').replace(queryParameters: query);

  @override
  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri('/auth/v1/token', <String, String>{'grant_type': 'password'}),
      body: <String, Object?>{'email': email, 'password': password},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri('/auth/v1/signup'),
      body: <String, Object?>{'email': email, 'password': password},
      headers: _headers,
    );
    final session = _sessionFrom(json);
    // A project with email confirmation returns a user object but no tokens.
    if (!session.hasTokens) {
      throw const AuthNetworkException(
        'account created but no session returned (email confirmation may be '
        'required)',
      );
    }
    return session;
  }

  @override
  Uri? oauthStartUrl(AuthMethod method, {required String redirectUri}) {
    final provider = _providerFor(method);
    if (provider == null) return null;
    return _uri('/auth/v1/authorize', <String, String>{
      'provider': provider,
      'redirect_to': redirectUri,
    });
  }

  @override
  Future<AccountSession> completeOAuth(AuthMethod method, Uri callbackUri) async {
    _assertConfigured();
    final provider = _providerFor(method);
    if (provider == null) {
      throw AuthConfigurationException('Supabase cannot serve ${method.name}');
    }
    final params =
        callbackUri.hasFragment && callbackUri.fragment.contains('=')
            ? Uri.splitQueryString(callbackUri.fragment)
            : callbackUri.queryParameters;
    final code = params['code'];
    if (code != null && code.isNotEmpty) {
      final json = await _http.postJson(
        _uri('/auth/v1/token', <String, String>{'grant_type': 'pkce'}),
        body: <String, Object?>{'auth_code': code, 'code_verifier': ''},
        headers: _headers,
      );
      return _sessionFrom(json);
    }
    final token = params['id_token'] ?? params['access_token'];
    if (token == null || token.isEmpty) {
      throw const AuthUnauthorizedException(
        'OAuth callback carried neither code nor token',
      );
    }
    final json = await _http.postJson(
      _uri('/auth/v1/token', <String, String>{'grant_type': 'id_token'}),
      body: <String, Object?>{'provider': provider, 'id_token': token},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signInAnonymously() async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri('/auth/v1/signin'),
      body: <String, Object?>{'data': const <String, Object?>{}},
      headers: _headers,
    );
    return _sessionFrom(json, isGuest: true);
  }

  @override
  Future<AccountSession> restoreSession(StoredCredentials credentials) async {
    final session = credentials.toSession();
    if (credentials.hasAnyToken && !session.isExpired(DateTime.now())) {
      return session;
    }
    final refresh = credentials.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('Supabase refresh token missing');
    }
    return refreshSession(session);
  }

  @override
  Future<AccountSession> refreshSession(AccountSession session) async {
    final refresh = session.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('Supabase session is not refreshable');
    }
    final json = await _http.postJson(
      _uri('/auth/v1/token', <String, String>{'grant_type': 'refresh_token'}),
      body: <String, Object?>{'refresh_token': refresh},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<void> signOut(AccountSession? session) async {
    final token = session?.accessToken;
    if (!isConfigured || token == null || token.isEmpty) return;
    try {
      await _http.postJson(
        _uri('/auth/v1/logout'),
        headers: <String, String>{
          ..._headers,
          'Authorization': 'Bearer $token',
        },
      );
    } on AuthException {
      // Logging out locally must succeed even if the server call fails.
    }
  }

  AccountSession _sessionFrom(
    Map<String, Object?> json, {
    bool isGuest = false,
  }) {
    final user = _userFrom(json, id, isGuest: isGuest);
    final expires =
        _expiresFrom(json, const <String>['expires_in']) ??
        _absoluteExpiry(json);
    return AccountSession(
      user: user.id.isEmpty ? user.copyWith(id: _str(json, 'sub')) : user,
      accessToken: _nullIfEmpty(_str(json, 'access_token')),
      refreshToken: _nullIfEmpty(_str(json, 'refresh_token')),
      expiresAt: expires,
      issuedAt: DateTime.now().toUtc(),
    );
  }

  DateTime? _absoluteExpiry(Map<String, Object?> json) {
    final at = _int(json, 'expires_at');
    if (at != null && at > 0) {
      return DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true);
    }
    return null;
  }

  static String? _providerFor(AuthMethod method) {
    switch (method) {
      case AuthMethod.google:
        return 'google';
      case AuthMethod.apple:
        return 'apple';
      case AuthMethod.email:
      case AuthMethod.anonymous:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Self-hosted
// ---------------------------------------------------------------------------

/// Endpoint layout for [SelfHostedAuthAdapter].
///
/// The defaults implement the reference contract in `docs/API_CONTRACTS.md`
/// and `server/schema.sql`; every path can be repointed without code changes.
class SelfHostedAuthConfig {
  const SelfHostedAuthConfig({
    required this.baseUrl,
    this.emailPath = '/v1/auth/email',
    this.signUpPath = '/v1/auth/register',
    this.oauthPath = '/v1/auth/oauth',
    this.refreshPath = '/v1/auth/refresh',
    this.userPath = '/v1/auth/me',
    this.oauthAuthorizePath = '/v1/auth/oauth/authorize',
    this.logoutPath = '/v1/auth/logout',
    this.apiKey = '',
  });

  final String baseUrl;
  final String emailPath;
  final String signUpPath;
  final String oauthPath;
  final String refreshPath;
  final String userPath;
  final String oauthAuthorizePath;
  final String logoutPath;
  final String apiKey;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  SelfHostedAuthConfig copyWith({
    String? baseUrl,
    String? emailPath,
    String? signUpPath,
    String? oauthPath,
    String? refreshPath,
    String? userPath,
    String? oauthAuthorizePath,
    String? logoutPath,
    String? apiKey,
  }) {
    return SelfHostedAuthConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      emailPath: emailPath ?? this.emailPath,
      signUpPath: signUpPath ?? this.signUpPath,
      oauthPath: oauthPath ?? this.oauthPath,
      refreshPath: refreshPath ?? this.refreshPath,
      userPath: userPath ?? this.userPath,
      oauthAuthorizePath: oauthAuthorizePath ?? this.oauthAuthorizePath,
      logoutPath: logoutPath ?? this.logoutPath,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'emailPath': emailPath,
    'signUpPath': signUpPath,
    'oauthPath': oauthPath,
    'refreshPath': refreshPath,
    'userPath': userPath,
    'oauthAuthorizePath': oauthAuthorizePath,
    'logoutPath': logoutPath,
    'apiKey': apiKey,
  };

  static SelfHostedAuthConfig fromJson(Map<String, Object?> json) {
    return SelfHostedAuthConfig(
      baseUrl: _str(json, 'baseUrl'),
      emailPath: _str(json, 'emailPath', '/v1/auth/email'),
      signUpPath: _str(json, 'signUpPath', '/v1/auth/register'),
      oauthPath: _str(json, 'oauthPath', '/v1/auth/oauth'),
      refreshPath: _str(json, 'refreshPath', '/v1/auth/refresh'),
      userPath: _str(json, 'userPath', '/v1/auth/me'),
      oauthAuthorizePath: _str(
        json,
        'oauthAuthorizePath',
        '/v1/auth/oauth/authorize',
      ),
      logoutPath: _str(json, 'logoutPath', '/v1/auth/logout'),
      apiKey: _str(json, 'apiKey'),
    );
  }
}

/// Generic adapter for a self-hosted SpotiFLAC sync/auth server.
class SelfHostedAuthAdapter implements AuthProvider {
  SelfHostedAuthAdapter({required this.config, AuthHttp? httpClient})
    : _http = httpClient ?? AuthHttp();

  final AuthHttp _http;
  SelfHostedAuthConfig config;

  @override
  String get id => 'selfhosted';

  @override
  String get displayName => 'Self-hosted';

  @override
  AccountBackendKind get kind => AccountBackendKind.selfHosted;

  @override
  Set<AuthMethod> get supportedMethods => const <AuthMethod>{
    AuthMethod.email,
    AuthMethod.google,
    AuthMethod.apple,
  };

  @override
  bool get isConfigured => config.isConfigured;

  void _assertConfigured() {
    if (!isConfigured) {
      throw const AuthConfigurationException(
        'self-hosted adapter needs a server URL',
      );
    }
  }

  Map<String, String> get _headers => config.apiKey.isEmpty
      ? const <String, String>{}
      : <String, String>{'X-Api-Key': config.apiKey};

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse(
    '${config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}$path',
  ).replace(queryParameters: query);

  @override
  Future<AccountSession> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri(config.emailPath),
      body: <String, Object?>{'email': email, 'password': password},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri(config.signUpPath),
      body: <String, Object?>{'email': email, 'password': password},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Uri? oauthStartUrl(AuthMethod method, {required String redirectUri}) {
    if (method == AuthMethod.email || method == AuthMethod.anonymous) {
      return null;
    }
    return _uri(config.oauthAuthorizePath, <String, String>{
      'provider': method.wireId,
      'redirect_uri': redirectUri,
    });
  }

  @override
  Future<AccountSession> completeOAuth(AuthMethod method, Uri callbackUri) async {
    _assertConfigured();
    final params =
        callbackUri.hasFragment && callbackUri.fragment.contains('=')
            ? Uri.splitQueryString(callbackUri.fragment)
            : callbackUri.queryParameters;
    final code = params['code'];
    final token = params['id_token'] ?? params['access_token'];
    if ((code == null || code.isEmpty) && (token == null || token.isEmpty)) {
      throw const AuthUnauthorizedException(
        'OAuth callback carried neither code nor token',
      );
    }
    final json = await _http.postJson(
      _uri(config.oauthPath),
      body: <String, Object?>{
        'provider': method.wireId,
        if (code != null && code.isNotEmpty) 'code': code,
        if (token != null && token.isNotEmpty) 'id_token': token,
        'redirect_uri': '${callbackUri.scheme}://${callbackUri.host}',
      },
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<AccountSession> signInAnonymously() async {
    _assertConfigured();
    final json = await _http.postJson(
      _uri(config.emailPath),
      body: const <String, Object?>{'anonymous': true},
      headers: _headers,
    );
    return _sessionFrom(json, isGuest: true);
  }

  @override
  Future<AccountSession> restoreSession(StoredCredentials credentials) async {
    final session = credentials.toSession();
    if (credentials.hasAnyToken && !session.isExpired(DateTime.now())) {
      return session;
    }
    final refresh = credentials.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('session is not refreshable');
    }
    return refreshSession(session);
  }

  @override
  Future<AccountSession> refreshSession(AccountSession session) async {
    final refresh = session.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AuthUnauthorizedException('session is not refreshable');
    }
    final json = await _http.postJson(
      _uri(config.refreshPath),
      body: <String, Object?>{'refreshToken': refresh},
      headers: _headers,
    );
    return _sessionFrom(json);
  }

  @override
  Future<void> signOut(AccountSession? session) async {
    final token = session?.accessToken;
    if (!isConfigured || token == null || token.isEmpty) return;
    try {
      await _http.postJson(
        _uri(config.logoutPath),
        headers: <String, String>{
          ..._headers,
          'Authorization': 'Bearer $token',
        },
      );
    } on AuthException {
      // Local sign-out always wins.
    }
  }

  AccountSession _sessionFrom(
    Map<String, Object?> json, {
    bool isGuest = false,
  }) {
    final user = _userFrom(json, id, isGuest: isGuest);
    final access = _nullIfEmpty(_str(json, 'accessToken'));
    final refresh = _nullIfEmpty(_str(json, 'refreshToken'));
    final expires =
        _expiresFrom(json, const <String>['expiresIn']) ?? _absoluteExpiry(json);
    return AccountSession(
      user: user,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expires,
      issuedAt: DateTime.now().toUtc(),
    );
  }

  DateTime? _absoluteExpiry(Map<String, Object?> json) {
    final raw = json['expiresAt'];
    if (raw is String) return DateTime.tryParse(raw)?.toUtc();
    final millis = _int(json, 'expiresAt');
    if (millis != null && millis > 0) {
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    return null;
  }
}
