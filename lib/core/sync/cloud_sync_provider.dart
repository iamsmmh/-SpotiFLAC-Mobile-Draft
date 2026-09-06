/// Cloud-sync provider port (Phase 6, repository pattern).
///
/// This is the **only** type the rest of the app talks to for sync. Concrete
/// backends — Firebase, Supabase, or a self-hosted API — implement this
/// interface in their own adapter packages/files and are registered at app
/// composition time. Nothing in the engine, services, or UI imports a
/// specific backend.
///
/// Implementation contract:
///   * [pull] returns every record in [scope] changed after [sinceRevision]
///     (or a full snapshot when null), as conflict-free as the backend can
///     make it; remaining conflicts are resolved by the orchestrator.
///   * [push] must be idempotent per record id — retries after network
///     failure resend the same revisions.
///   * Auth tokens must be stored via the platform secure store
///     (`core/data/secure_store.dart`), never in plain preferences, and
///     refreshed inside the adapter (the orchestrator only surfaces
///     [SyncAuthException] to the UI).
library;

import 'package:spotiflac_android/core/sync/sync_entities.dart';

/// Thrown when the backend rejects the current credentials and interactive
/// sign-in is required again.
class SyncAuthException implements Exception {
  const SyncAuthException([this.message = 'authentication required']);

  final String message;

  @override
  String toString() => 'SyncAuthException: $message';
}

/// Thrown for transient transport/backend failures worth retrying later.
class SyncUnavailableException implements Exception {
  const SyncUnavailableException([this.message = 'sync backend unavailable']);

  final String message;

  @override
  String toString() => 'SyncUnavailableException: $message';
}

/// Repository-style port for account + sync backends.
abstract interface class CloudSyncProvider {
  /// Stable identifier: `firebase`, `supabase`, `selfhosted`, …
  String get id;

  /// Human-readable backend label for the settings UI (e.g. server URL).
  String get displayName;

  /// Currently signed-in user, or null.
  Future<UserProfile?> currentUser();

  /// Interactive/token sign-in. Implementations own their credential UX
  /// (OAuth flow, email link, API key). Returns the signed-in profile.
  Future<UserProfile> signIn(Map<String, Object?> credentials);

  /// Signs out and scrubs locally held tokens for this provider.
  Future<void> signOut();

  /// Fetches records in [scope] newer than [sinceRevision]; null → full
  /// snapshot. Must include tombstones so deletions propagate.
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision});

  /// Uploads [records] (already merged locally). Returns the server-assigned
  /// revision per accepted record id for outbox bookkeeping.
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> records);
}

/// Default provider: sync is **off**. This is not a mock — it is the honest
/// "no backend configured" state that keeps every sync surface inert until a
/// real adapter (see `docs/CLOUD_SYNC.md`) is registered.
class NoOpCloudSyncProvider implements CloudSyncProvider {
  const NoOpCloudSyncProvider();

  @override
  String get id => 'none';

  @override
  String get displayName => 'Not configured';

  @override
  Future<UserProfile?> currentUser() async => null;

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) {
    throw const SyncUnavailableException(
      'no sync backend is configured for this build',
    );
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision}) async {
    return const <SyncRecord>[];
  }

  @override
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> records) {
    throw const SyncUnavailableException(
      'no sync backend is configured for this build',
    );
  }
}
