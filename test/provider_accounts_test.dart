import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/secure_store.dart';
import 'package:spotiflac_android/providers/provider_accounts_provider.dart';
import 'package:spotiflac_android/services/provider_credentials.dart';

/// In-memory [SecureStore] fake. Implements the facade (not the
/// plugin) so the test only depends on the app's own API.
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

  @override
  Future<void> deleteRetiredSecrets() async {}
}

void main() {
  ProviderContainer containerWith(FakeSecureStore store) {
    return ProviderContainer(
      overrides: [secureStoreProvider.overrideWithValue(store)],
    );
  }

  group('provider account descriptors', () {
    test('cover every known credential exactly once', () {
      final covered = <String>[];
      for (final account in providerAccounts) {
        expect(account.providerLabel.isNotEmpty, isTrue);
        expect(account.description.isNotEmpty, isTrue);
        expect(account.fields.isNotEmpty, isTrue);
        for (final field in account.fields) {
          expect(field.label.isNotEmpty, isTrue);
          expect(field.hint.isNotEmpty, isTrue);
          covered.add(field.credentialName);
        }
      }
      expect(covered.toSet(), StreamCredentialNames.all.toSet());
      expect(covered.length, StreamCredentialNames.all.length);
    });
  });

  group('ProviderAccountsNotifier', () {
    test('load reports configured flags without exposing values', () async {
      final store = FakeSecureStore();
      await store.writeToken(
        StreamCredentialNames.tidalAccessToken,
        'secret-token',
      );
      await store.writeToken(StreamCredentialNames.qobuzAppId, '   ');
      final container = containerWith(store);
      addTearDown(container.dispose);

      await container.read(providerAccountsProvider.notifier).load();
      final state = container.read(providerAccountsProvider);

      expect(state.loaded, isTrue);
      expect(
        state.isConfigured(StreamCredentialNames.tidalAccessToken),
        isTrue,
      );
      // Blank values count as missing.
      expect(state.isConfigured(StreamCredentialNames.qobuzAppId), isFalse);
      expect(
        state.isConfigured(StreamCredentialNames.deezerArl),
        isFalse,
      );
      expect(state.configuredCount, 1);
    });

    test('save trims and flags, blank save clears', () async {
      final store = FakeSecureStore();
      final container = containerWith(store);
      addTearDown(container.dispose);
      final notifier = container.read(providerAccountsProvider.notifier);

      await notifier.save(StreamCredentialNames.deezerArl, '  arl-value  ');
      expect(
        await store.readToken(StreamCredentialNames.deezerArl),
        'arl-value',
      );
      expect(
        container
            .read(providerAccountsProvider)
            .isConfigured(StreamCredentialNames.deezerArl),
        isTrue,
      );

      await notifier.save(StreamCredentialNames.deezerArl, '   ');
      expect(
        await store.readToken(StreamCredentialNames.deezerArl),
        isNull,
      );
      expect(
        container
            .read(providerAccountsProvider)
            .isConfigured(StreamCredentialNames.deezerArl),
        isFalse,
      );
    });

    test('clear removes the token and the flag', () async {
      final store = FakeSecureStore();
      await store.writeToken(
        StreamCredentialNames.appleDeveloperToken,
        'jwt',
      );
      final container = containerWith(store);
      addTearDown(container.dispose);
      final notifier = container.read(providerAccountsProvider.notifier);
      await notifier.load();
      expect(
        container
            .read(providerAccountsProvider)
            .isConfigured(StreamCredentialNames.appleDeveloperToken),
        isTrue,
      );

      await notifier.clear(StreamCredentialNames.appleDeveloperToken);
      expect(
        await store.readToken(StreamCredentialNames.appleDeveloperToken),
        isNull,
      );
      expect(
        container
            .read(providerAccountsProvider)
            .isConfigured(StreamCredentialNames.appleDeveloperToken),
        isFalse,
      );
    });
  });
}
