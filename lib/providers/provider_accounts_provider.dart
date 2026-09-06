import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/core/data/secure_store.dart';
import 'package:spotiflac_android/services/provider_credentials.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('ProviderAccounts');

/// Injectable secure-storage handle. Overridden in tests with a fake.
final secureStoreProvider = Provider<SecureStore>((ref) {
  return SecureStore.instance;
});

/// One credential field on the Provider accounts page.
class ProviderAccountField {
  const ProviderAccountField({
    required this.credentialName,
    required this.label,
    required this.hint,
  });

  /// Key into [StreamCredentialNames.all]; stored via `SecureStore.writeToken`.
  final String credentialName;
  final String label;
  final String hint;
}

/// One provider card on the Provider accounts page.
class ProviderAccount {
  const ProviderAccount({
    required this.providerLabel,
    required this.description,
    required this.fields,
  });

  final String providerLabel;
  final String description;
  final List<ProviderAccountField> fields;
}

/// NOTE(l10n): English-first while the surface stabilizes; staged for Crowdin
/// with the rest of the provider-accounts strings (see `StagedStrings`).
const List<ProviderAccount> providerAccounts = <ProviderAccount>[
  ProviderAccount(
    providerLabel: 'Tidal',
    description: 'OAuth access token from your TIDAL session enables '
        'lossless FLAC streams.',
    fields: <ProviderAccountField>[
      ProviderAccountField(
        credentialName: StreamCredentialNames.tidalAccessToken,
        label: 'Access token',
        hint: 'Paste your TIDAL access token',
      ),
    ],
  ),
  ProviderAccount(
    providerLabel: 'Qobuz',
    description: 'App ID plus user auth token enable up to 24-bit studio '
        'FLAC streams.',
    fields: <ProviderAccountField>[
      ProviderAccountField(
        credentialName: StreamCredentialNames.qobuzAppId,
        label: 'App ID',
        hint: 'Qobuz app ID',
      ),
      ProviderAccountField(
        credentialName: StreamCredentialNames.qobuzAuthToken,
        label: 'User auth token',
        hint: 'Qobuz user auth token',
      ),
    ],
  ),
  ProviderAccount(
    providerLabel: 'Apple Music',
    description: 'A signed MusicKit developer token (JWT) enables '
        'Apple-hosted preview streams matched against your library.',
    fields: <ProviderAccountField>[
      ProviderAccountField(
        credentialName: StreamCredentialNames.appleDeveloperToken,
        label: 'Developer token',
        hint: 'MusicKit developer JWT',
      ),
    ],
  ),
  ProviderAccount(
    providerLabel: 'Deezer',
    description: 'The `arl` cookie from a logged-in Deezer web session '
        'enables full-track and FLAC streams on eligible accounts.',
    fields: <ProviderAccountField>[
      ProviderAccountField(
        credentialName: StreamCredentialNames.deezerArl,
        label: 'ARL cookie',
        hint: 'Deezer arl cookie value',
      ),
    ],
  ),
  ProviderAccount(
    providerLabel: 'Amazon Music',
    description: 'AMAPI bearer and device tokens enable HD/Ultra HD '
        'streams.',
    fields: <ProviderAccountField>[
      ProviderAccountField(
        credentialName: StreamCredentialNames.amazonBearerToken,
        label: 'Bearer token',
        hint: 'AMAPI bearer token',
      ),
      ProviderAccountField(
        credentialName: StreamCredentialNames.amazonDeviceToken,
        label: 'Device token',
        hint: 'AMAPI device token',
      ),
    ],
  ),
];

class ProviderAccountsState {
  const ProviderAccountsState({
    this.configured = const <String, bool>{},
    this.loaded = false,
  });

  /// Credential name → true when a non-empty token is stored.
  final Map<String, bool> configured;
  final bool loaded;

  bool isConfigured(String credentialName) =>
      configured[credentialName] == true;

  int get configuredCount =>
      configured.values.where((value) => value).length;

  ProviderAccountsState copyWith({
    Map<String, bool>? configured,
    bool? loaded,
  }) {
    return ProviderAccountsState(
      configured: configured ?? this.configured,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// Owns the streaming credential set in encrypted storage. Tokens apply to
/// the next stream resolution immediately — handlers read secure storage at
/// request time, so no restart or cache invalidation is needed.
class ProviderAccountsNotifier extends Notifier<ProviderAccountsState> {
  @override
  ProviderAccountsState build() {
    return const ProviderAccountsState();
  }

  SecureStore get _store => ref.read(secureStoreProvider);

  /// Reads the configured flags for every known credential. Stored token
  /// values are never surfaced — the UI only learns whether one exists.
  Future<void> load() async {
    final configured = <String, bool>{};
    for (final name in StreamCredentialNames.all) {
      try {
        final stored = await _store.readToken(name);
        configured[name] = stored != null && stored.trim().isNotEmpty;
      } catch (e) {
        _log.w('Failed to read credential flag for $name: $e');
        configured[name] = false;
      }
    }
    state = state.copyWith(configured: configured, loaded: true);
  }

  /// Saves [value] for [credentialName]; a blank value clears the token.
  Future<void> save(String credentialName, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await clear(credentialName);
      return;
    }
    await _store.writeToken(credentialName, trimmed);
    _log.i('Saved streaming credential: $credentialName');
    state = state.copyWith(
      configured: <String, bool>{...state.configured, credentialName: true},
    );
  }

  Future<void> clear(String credentialName) async {
    await _store.deleteToken(credentialName);
    _log.i('Cleared streaming credential: $credentialName');
    state = state.copyWith(
      configured: <String, bool>{...state.configured, credentialName: false},
    );
  }
}

final providerAccountsProvider =
    NotifierProvider<ProviderAccountsNotifier, ProviderAccountsState>(
      ProviderAccountsNotifier.new,
    );
