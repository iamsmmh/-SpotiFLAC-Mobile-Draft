/// Optional social layer — services (Feature Group 11).
///
/// Every entry point short-circuits when [SocialFeatureFlags] says the feature
/// is off, so the module is inert unless the user explicitly opts in. Backend
/// access goes through [SocialBackend]; with no backend registered the services
/// degrade to local-only behaviour (share links still generate, feeds are
/// empty) rather than throwing.
library;

import 'dart:convert';

import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';
import 'package:spotiflac_android/ecosystem/social/social_models.dart';
import 'package:sqflite/sqflite.dart';

/// Remote operations the social layer needs. Implemented by whichever backend
/// the user configures (the existing Firebase/Supabase/self-hosted sync
/// adapters can each grow one).
abstract interface class SocialBackend {
  Future<SocialProfile?> fetchProfile(String userId);

  Future<void> publishProfile(SocialProfile profile);

  Future<SharedPlaylist?> fetchSharedPlaylist(String shareId);

  Future<void> publishPlaylist(SharedPlaylist playlist);

  Future<void> unpublishPlaylist(String shareId);

  Future<void> follow(String userId);

  Future<void> unfollow(String userId);

  Future<List<String>> following();

  Future<List<ActivityEntry>> activityFeed({int limit});
}

/// Reads/writes the social flags.
class SocialSettings {
  SocialSettings(this._store);

  static const String storageKey = 'social.flags';

  final KeyValueStore _store;

  Future<SocialFeatureFlags> read() async {
    return SocialFeatureFlags.tryDecode(await _store.read(storageKey)) ??
        SocialFeatureFlags.disabled;
  }

  Future<void> write(SocialFeatureFlags flags) async {
    await _store.write(storageKey, jsonEncode(flags.toJson()));
  }

  /// Turning the master switch off also clears the sub-flags, so re-enabling
  /// later starts from a private default instead of silently republishing.
  Future<SocialFeatureFlags> setEnabled(bool enabled) async {
    final flags = enabled
        ? (await read()).copyWith(enabled: true)
        : SocialFeatureFlags.disabled;
    await write(flags);
    return flags;
  }
}

/// Port for social payload caching.
///
/// An interface so tests can substitute an in-memory double: a class with
/// private fields cannot be `implement`ed from another library.
abstract interface class SocialCacheStore {
  Future<Map<String, Object?>?> read(String key);

  Future<void> write(String key, Map<String, Object?> payload);

  Future<void> clear();
}

/// Local cache for social payloads, backed by `ec_social_cache`.
///
/// Keeps profiles and feeds readable offline and lets the UI render instantly
/// before the network answers.
class SocialCache implements SocialCacheStore {
  SocialCache({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  @override
  Future<Map<String, Object?>?> read(String key) async {
    final db = await _database.database;
    final rows = await db.query(
      tableSocialCache,
      where: 'cache_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final decoded = jsonDecode(rows.first['payload_json']?.toString() ?? '');
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      return null;
    }
    return null;
  }

  @override
  Future<void> write(String key, Map<String, Object?> payload) async {
    final db = await _database.database;
    await db.insert(tableSocialCache, <String, Object?>{
      'cache_key': key,
      'payload_json': jsonEncode(payload),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(tableSocialCache);
  }
}

/// Public profiles.
class ProfileSystem {
  ProfileSystem({
    required SocialSettings settings,
    SocialBackend? backend,
    SocialCacheStore? cache,
  }) : _settings = settings,
       _backend = backend,
       _cache = cache ?? SocialCache();

  final SocialSettings _settings;
  final SocialBackend? _backend;
  final SocialCacheStore _cache;

  /// Fetches a profile, falling back to the local cache when offline.
  /// Returns null when social features are disabled.
  Future<SocialProfile?> profile(String userId) async {
    if (!(await _settings.read()).enabled) return null;

    final backend = _backend;
    if (backend != null) {
      try {
        final fetched = await backend.fetchProfile(userId);
        if (fetched != null) {
          await _cache.write('profile:$userId', fetched.toJson());
          return fetched;
        }
      } catch (_) {
        // Fall through to the cache: a dead backend must not blank the UI.
      }
    }
    final cached = await _cache.read('profile:$userId');
    return cached == null ? null : SocialProfile.tryParse(cached);
  }

  /// Publishes the local profile. No-op unless the user enabled public
  /// profiles.
  Future<bool> publish(SocialProfile profile) async {
    if (!(await _settings.read()).canPublishProfile) return false;
    final backend = _backend;
    if (backend == null) return false;
    await backend.publishProfile(profile);
    await _cache.write('profile:${profile.userId}', profile.toJson());
    return true;
  }

  /// Normalizes user input into a valid handle, or null when unusable.
  static String? normalizeHandle(String raw) {
    final cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.]+'), '_')
        .replaceAll(RegExp(r'_{2,}'), '_')
        .replaceAll(RegExp(r'^[_.]+|[_.]+$'), '');
    if (cleaned.length < 3 || cleaned.length > 30) return null;
    return cleaned;
  }
}

/// Playlist sharing + collaboration.
class PlaylistSharing {
  PlaylistSharing({
    required SocialSettings settings,
    SocialBackend? backend,
    SocialCacheStore? cache,
  }) : _settings = settings,
       _backend = backend,
       _cache = cache ?? SocialCache();

  final SocialSettings _settings;
  final SocialBackend? _backend;
  final SocialCacheStore _cache;

  /// Publishes a playlist and returns its share record.
  ///
  /// Returns null when sharing is disabled.
  Future<SharedPlaylist?> share({
    required String playlistId,
    required String ownerId,
    required String title,
    String description = '',
    String? coverUrl,
    int trackCount = 0,
    PlaylistShareMode mode = PlaylistShareMode.view,
    DateTime? now,
  }) async {
    if (!(await _settings.read()).canSharePlaylists) return null;

    final stamp = (now ?? DateTime.now()).toUtc();
    final shared = SharedPlaylist(
      shareId: buildShareId(playlistId: playlistId, ownerId: ownerId),
      playlistId: playlistId,
      ownerId: ownerId,
      title: title,
      description: description,
      coverUrl: coverUrl,
      trackCount: trackCount,
      mode: mode,
      sharedAt: stamp,
    );

    await _cache.write('share:${shared.shareId}', shared.toJson());
    try {
      await _backend?.publishPlaylist(shared);
    } catch (_) {
      // The link is still valid locally; a later sync retries the publish.
    }
    return shared;
  }

  Future<SharedPlaylist?> resolve(String shareId) async {
    if (!(await _settings.read()).canSharePlaylists) return null;
    final backend = _backend;
    if (backend != null) {
      try {
        final fetched = await backend.fetchSharedPlaylist(shareId);
        if (fetched != null) {
          await _cache.write('share:$shareId', fetched.toJson());
          return fetched;
        }
      } catch (_) {
        // Fall back to cache.
      }
    }
    final cached = await _cache.read('share:$shareId');
    return cached == null ? null : SharedPlaylist.tryParse(cached);
  }

  /// Opens a `spotiflac://playlist/shared/<id>` link.
  Future<SharedPlaylist?> resolveLink(Uri uri) async {
    final shareId = SharedPlaylist.shareIdFromLink(uri);
    if (shareId == null) return null;
    return resolve(shareId);
  }

  Future<void> revoke(String shareId) async {
    if (!(await _settings.read()).canSharePlaylists) return;
    await _backend?.unpublishPlaylist(shareId);
  }

  /// Deterministic, non-guessable share id derived from owner + playlist.
  ///
  /// Deterministic so re-sharing the same playlist reuses one link instead of
  /// littering the backend with duplicates.
  static String buildShareId({
    required String playlistId,
    required String ownerId,
  }) {
    return sha256Hex(utf8.encode('$ownerId\u001f$playlistId')).substring(0, 22);
  }
}

/// Follow graph.
class FollowSystem {
  FollowSystem({required SocialSettings settings, SocialBackend? backend})
    : _settings = settings,
      _backend = backend;

  final SocialSettings _settings;
  final SocialBackend? _backend;

  Future<bool> follow(String userId) async {
    if (!(await _settings.read()).canFollow) return false;
    final backend = _backend;
    if (backend == null) return false;
    await backend.follow(userId);
    return true;
  }

  Future<bool> unfollow(String userId) async {
    if (!(await _settings.read()).canFollow) return false;
    final backend = _backend;
    if (backend == null) return false;
    await backend.unfollow(userId);
    return true;
  }

  Future<List<String>> following() async {
    if (!(await _settings.read()).canFollow) return const <String>[];
    try {
      return await _backend?.following() ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }
}

/// Activity feed.
class ActivityFeed {
  ActivityFeed({
    required SocialSettings settings,
    SocialBackend? backend,
    SocialCacheStore? cache,
  }) : _settings = settings,
       _backend = backend,
       _cache = cache ?? SocialCache();

  static const String _cacheKey = 'feed:home';

  final SocialSettings _settings;
  final SocialBackend? _backend;
  final SocialCacheStore _cache;

  /// Newest first; empty when the feature is off.
  Future<List<ActivityEntry>> entries({int limit = 50}) async {
    if (!(await _settings.read()).canShowFeed) return const <ActivityEntry>[];

    final backend = _backend;
    if (backend != null) {
      try {
        final fetched = await backend.activityFeed(limit: limit);
        await _cache.write(_cacheKey, <String, Object?>{
          'entries': fetched
              .map((entry) => entry.toJson())
              .toList(growable: false),
        });
        return sortNewestFirst(fetched);
      } catch (_) {
        // Fall through to the cached feed.
      }
    }

    final cached = await _cache.read(_cacheKey);
    final raw = cached?['entries'];
    if (raw is! List) return const <ActivityEntry>[];
    final entries = <ActivityEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final entry = ActivityEntry.tryParse(Map<String, Object?>.from(item));
      if (entry != null) entries.add(entry);
    }
    return sortNewestFirst(entries);
  }

  /// Pure ordering helper, exposed for tests.
  static List<ActivityEntry> sortNewestFirst(List<ActivityEntry> entries) {
    final sorted = List<ActivityEntry>.of(entries)
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return List<ActivityEntry>.unmodifiable(sorted);
  }
}
