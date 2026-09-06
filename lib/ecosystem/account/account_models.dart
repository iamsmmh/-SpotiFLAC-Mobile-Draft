/// Account domain values (Feature Group 1).
///
/// Pure Dart: no Flutter, no platform channels, no I/O. Adapters translate
/// these to/from their wire format; the UI only ever sees [AccountState].
library;

/// Credential entry points a backend adapter can support.
enum AuthMethod {
  email,
  google,
  apple,
  anonymous;

  String get wireId => name;
}

/// Lifecycle of the app-level account session.
enum AccountStatus {
  /// No session and no backend configured (or the user signed out).
  signedOut,

  /// A sign-in round trip is in flight.
  signingIn,

  /// Local guest profile: full app functionality, no server account.
  guest,

  /// Authenticated against a backend adapter.
  signedIn,

  /// Last operation failed; [AccountState.errorMessage] carries the reason.
  error;

  bool get isBusy => this == AccountStatus.signingIn;
}

/// Which adapter family is currently bound.
enum AccountBackendKind {
  none,
  anonymous,
  firebase,
  supabase,
  selfHosted;

  String get wireId => name;

  static AccountBackendKind fromWire(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    for (final kind in AccountBackendKind.values) {
      if (kind.wireId == normalized) return kind;
    }
    return AccountBackendKind.none;
  }
}

/// A (possibly anonymous) account profile.
class AccountUser {
  const AccountUser({
    required this.id,
    required this.providerId,
    this.email = '',
    this.displayName,
    this.avatarUrl,
    this.isGuest = false,
    this.emailVerified = false,
  });

  /// Opaque, backend-scoped user id. Stable across sessions.
  final String id;

  /// Adapter id that issued this profile (`firebase`, `supabase`, …).
  final String providerId;

  final String email;
  final String? displayName;
  final String? avatarUrl;
  final bool isGuest;
  final bool emailVerified;

  /// What the UI shows when there is no name and no email (guest mode).
  String get label {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return isGuest ? 'Guest' : 'Signed in';
  }

  AccountUser copyWith({
    String? id,
    String? providerId,
    String? email,
    String? displayName,
    String? avatarUrl,
    bool? isGuest,
    bool? emailVerified,
  }) {
    return AccountUser(
      id: id ?? this.id,
      providerId: providerId ?? this.providerId,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isGuest: isGuest ?? this.isGuest,
      emailVerified: emailVerified ?? this.emailVerified,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'providerId': providerId,
    'email': email,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'isGuest': isGuest,
    'emailVerified': emailVerified,
  };

  static AccountUser? tryParse(Map<String, Object?> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return AccountUser(
      id: id,
      providerId: json['providerId']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      displayName: json['displayName']?.toString(),
      avatarUrl: json['avatarUrl']?.toString(),
      isGuest: json['isGuest'] == true,
      emailVerified: json['emailVerified'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountUser &&
      other.id == id &&
      other.providerId == providerId &&
      other.email == email &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      other.isGuest == isGuest &&
      other.emailVerified == emailVerified;

  @override
  int get hashCode => Object.hash(
    id,
    providerId,
    email,
    displayName,
    avatarUrl,
    isGuest,
    emailVerified,
  );

  @override
  String toString() => 'AccountUser($id, ${isGuest ? 'guest' : email})';
}

/// An authenticated session: profile + refreshable credentials.
class AccountSession {
  AccountSession({
    required this.user,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
    DateTime? issuedAt,
  }) : issuedAt = issuedAt ?? _epoch;

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  final AccountUser user;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final DateTime issuedAt;

  bool get hasTokens =>
      (accessToken?.isNotEmpty ?? false) || (refreshToken?.isNotEmpty ?? false);

  bool get canRefresh => refreshToken?.isNotEmpty ?? false;

  /// True when the access token carries an expiry that has already passed.
  /// A session without an expiry is treated as long-lived (refresh tokens,
  /// anonymous sessions).
  bool isExpired(DateTime now) {
    final expiresAt = this.expiresAt;
    if (expiresAt == null) return false;
    return !now.isBefore(expiresAt);
  }

  /// True when the token is inside the refresh lead window.
  bool needsRefresh(DateTime now, {Duration lead = const Duration(minutes: 2)}) {
    final expiresAt = this.expiresAt;
    if (expiresAt == null) return false;
    return !now.isBefore(expiresAt.subtract(lead));
  }

  AccountSession copyWith({
    AccountUser? user,
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    DateTime? issuedAt,
  }) {
    return AccountSession(
      user: user ?? this.user,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      issuedAt: issuedAt ?? this.issuedAt,
    );
  }

  @override
  String toString() =>
      'AccountSession(${user.id}, expires: ${expiresAt?.toIso8601String()})';
}

/// Immutable UI-facing account snapshot.
class AccountState {
  AccountState({
    this.status = AccountStatus.signedOut,
    this.user,
    this.backend = AccountBackendKind.none,
    this.errorMessage,
    this.availableMethods = const <AuthMethod>{},
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? _epoch;

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  static final AccountState initial = AccountState();

  final AccountStatus status;
  final AccountUser? user;
  final AccountBackendKind backend;
  final String? errorMessage;

  /// Methods the *bound* adapter supports. Empty ⇒ the UI hides its controls
  /// instead of offering buttons that cannot work.
  final Set<AuthMethod> availableMethods;

  final DateTime updatedAt;

  bool get isSignedIn =>
      status == AccountStatus.signedIn || status == AccountStatus.guest;

  bool get isGuest => status == AccountStatus.guest;

  bool get isAuthenticated => status == AccountStatus.signedIn;

  bool get isConfigured => backend != AccountBackendKind.none;

  AccountState copyWith({
    AccountStatus? status,
    AccountUser? user,
    AccountBackendKind? backend,
    String? errorMessage,
    Set<AuthMethod>? availableMethods,
    DateTime? updatedAt,
    bool clearError = false,
    bool clearUser = false,
  }) {
    return AccountState(
      status: status ?? this.status,
      user: clearUser ? null : (user ?? this.user),
      backend: backend ?? this.backend,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      availableMethods: availableMethods ?? this.availableMethods,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'AccountState(${status.name}, ${backend.wireId}, ${user?.id})';
}
