import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/core/data/secure_store.dart';
import 'package:spotimusic/ecosystem/account/account_models.dart';
import 'package:spotimusic/ecosystem/account/account_service.dart';
import 'package:spotimusic/ecosystem/account/auth_adapters.dart';
import 'package:spotimusic/ecosystem/account/auth_provider.dart';
import 'package:spotimusic/ecosystem/account/token_store.dart';
import 'package:spotimusic/ecosystem/ecosystem_kv.dart';

class FakeSecureStore implements SecureStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> writeToken(String name, String value) async {
    values[SecureStoreKeys.token(name)] = value;
  }

  @override
  Future<String?> readToken(String name) async =>
      values[SecureStoreKeys.token(name)];

  @override
  Future<void> deleteToken(String name) async {
    values.remove(SecureStoreKeys.token(name));
  }

  @override
  Future<void> deleteRetiredSecrets() async {}

  @override
  Future<void> writeSecret(String name, String value) async {
    values[SecureStoreKeys.secret(name)] = value;
  }

  @override
  Future<String?> readSecret(String name) async =>
      values[SecureStoreKeys.secret(name)];

  @override
  Future<void> writeExtensionSignature(String extensionId, String hex) async {
    values[SecureStoreKeys.extensionSignature(extensionId)] = hex;
  }

  @override
  Future<String?> readExtensionSignature(String extensionId) async =>
      values[SecureStoreKeys.extensionSignature(extensionId)];

  @override
  Future<void> deleteExtensionSignature(String extensionId) async {
    values.remove(SecureStoreKeys.extensionSignature(extensionId));
  }
}

void main() {
  group('AccountSession', () {
    test('a session without expiry is long lived', () {
      final session = AccountSession(
        user: const AccountUser(id: 'u1', providerId: 'firebase'),
      );
      expect(session.isExpired(DateTime(2100, 1, 1)), isFalse);
      expect(session.needsRefresh(DateTime(2100, 1, 1)), isFalse);
      expect(session.hasTokens, isFalse);
    });

    test('an expiring session reports inside the refresh lead window', () {
      final now = DateTime.utc(2026, 9, 1, 12);
      final session = AccountSession(
        user: const AccountUser(id: 'u1', providerId: 'firebase'),
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: now.add(const Duration(seconds: 30)),
      );
      expect(session.isExpired(now), isFalse);
      expect(session.needsRefresh(now), isTrue);
      expect(session.canRefresh, isTrue);
      expect(session.isExpired(now.add(const Duration(minutes: 1))), isTrue);
    });
  });

  group('StoredCredentials', () {
    test('round trips through JSON', () {
      const credentials = StoredCredentials(
        providerId: 'supabase',
        user: AccountUser(
          id: 'u1',
          providerId: 'supabase',
          email: 'a@b.c',
          displayName: 'Ada',
        ),
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAtEpochMs: 1700000000000,
      );
      final parsed = StoredCredentials.tryParse(credentials.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.providerId, 'supabase');
      expect(parsed.user.email, 'a@b.c');
      expect(parsed.accessToken, 'access');
      expect(parsed.hasAnyToken, isTrue);
      expect(parsed.toSession().expiresAt?.isUtc, isTrue);
    });

    test('rejects malformed payloads', () {
      expect(StoredCredentials.tryParse(const <String, Object?>{}), isNull);
      expect(
        StoredCredentials.tryParse(const <String, Object?>{'providerId': 'x'}),
        isNull,
      );
    });
  });

  group('AccountTokenStore', () {
    test('tokens land under the secure-store namespace', () async {
      final secure = FakeSecureStore();
      final store = AccountTokenStore(secure);
      await store.persist(
        'firebase',
        AccountSession(
          user: const AccountUser(id: 'u1', providerId: 'firebase'),
          accessToken: 'aaa',
          refreshToken: 'rrr',
        ),
      );
      expect(
        secure.values[SecureStoreKeys.token('account.firebase.access')],
        'aaa',
      );
      expect(
        secure.values[SecureStoreKeys.token('account.firebase.refresh')],
        'rrr',
      );
      expect(
        SecureStorePolicy.isAllowedKey(
          SecureStoreKeys.token('account.firebase.access'),
        ),
        isTrue,
      );

      final read = await store.read('firebase');
      expect(read, isNotNull);
      expect(read!.accessToken, 'aaa');

      await store.clear('firebase');
      expect(await store.read('firebase'), isNull);
      expect(
        secure.values.containsKey(
          SecureStoreKeys.token('account.firebase.access'),
        ),
        isFalse,
      );
    });
  });

  group('adapters', () {
    test('Firebase advertises only the methods it can serve', () {
      final bare = FirebaseAuthAdapter(apiKey: '');
      expect(bare.isConfigured, isFalse);
      expect(bare.supportedMethods, isEmpty);

      final emailOnly = FirebaseAuthAdapter(apiKey: 'key');
      expect(emailOnly.supportedMethods, <AuthMethod>{AuthMethod.email});
      expect(emailOnly.oauthStartUrl(
            AuthMethod.google,
            redirectUri: 'spotimusic://oauth',
          ), isNull);

      final withGoogle = FirebaseAuthAdapter(
        apiKey: 'key',
        googleClientId: 'client.apps.googleusercontent.com',
      );
      expect(
        withGoogle.supportedMethods,
        <AuthMethod>{AuthMethod.email, AuthMethod.google},
      );
      expect(
        withGoogle
            .oauthStartUrl(
              AuthMethod.google,
              redirectUri: 'spotimusic://oauth',
            )
            ?.queryParameters['client_id'],
        'client.apps.googleusercontent.com',
      );
    });

    test('an unconfigured adapter explains itself', () async {
      final adapter = FirebaseAuthAdapter(apiKey: '');
      expect(
        () => adapter.signInWithEmail(email: 'a@b.c', password: 'p'),
        throwsA(isA<AuthConfigurationException>()),
      );
    });

    test('self-hosted config round trips', () {
      const config = SelfHostedAuthConfig(
        baseUrl: 'https://sync.example.com',
        apiKey: 'k',
      );
      final restored = SelfHostedAuthConfig.fromJson(config.toJson());
      expect(restored.baseUrl, 'https://sync.example.com');
      expect(restored.emailPath, '/v1/auth/email');
      expect(restored.apiKey, 'k');
    });
  });

  group('AccountService', () {
    test('guest mode works with no backend configured', () async {
      final service = AccountService(
        tokenStore: AccountTokenStore(FakeSecureStore()),
        preferences: MemoryKeyValueStore(),
      );
      addTearDown(service.dispose);
      await service.continueAsGuest();

      expect(service.state.status, AccountStatus.guest);
      expect(service.state.isSignedIn, isTrue);
      expect(service.state.user?.isGuest, isTrue);
      expect(service.state.availableMethods, contains(AuthMethod.anonymous));
      expect(await service.accessToken(), isNull);
    });

    test('email sign-in fails loudly when no adapter can serve it', () async {
      final service = AccountService(
        tokenStore: AccountTokenStore(FakeSecureStore()),
        preferences: MemoryKeyValueStore(),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.signInWithEmail(email: 'a@b.c', password: 'p'),
        throwsA(isA<AuthException>()),
      );
      expect(service.state.status, AccountStatus.error);
      expect(service.state.errorMessage, isNotNull);
    });

    test('sign-out clears the session and the keystore entry', () async {
      final secure = FakeSecureStore();
      final service = AccountService(
        tokenStore: AccountTokenStore(secure),
        preferences: MemoryKeyValueStore(),
      );
      addTearDown(service.dispose);
      await service.continueAsGuest();
      await service.signOut();

      expect(service.state.status, AccountStatus.signedOut);
      expect(service.state.user, isNull);
      expect(service.session, isNull);
    });

    test('state changes are broadcast', () async {
      final service = AccountService(
        tokenStore: AccountTokenStore(FakeSecureStore()),
        preferences: MemoryKeyValueStore(),
      );
      addTearDown(service.dispose);
      final seen = <AccountStatus>[];
      final sub = service.changes.listen((state) => seen.add(state.status));
      addTearDown(sub.cancel);

      await service.continueAsGuest();
      await service.signOut();
      // Broadcast delivery to the async* changes stream is scheduled as a
      // microtask after signOut completes; pump once before asserting.
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(AccountStatus.guest));
      expect(seen.last, AccountStatus.signedOut);
    });
  });
}
