import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';
import 'package:spotiflac_android/ecosystem/social/social_models.dart';
import 'package:spotiflac_android/ecosystem/social/social_service.dart';

/// In-memory key/value store.
class _MemoryStore implements KeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// In-memory social cache so tests never touch SQLite.
class _MemoryCache implements SocialCacheStore {
  final Map<String, Map<String, Object?>> entries =
      <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, Map<String, Object?> payload) async {
    entries[key] = payload;
  }

  @override
  Future<void> clear() async => entries.clear();
}

class _RecordingBackend implements SocialBackend {
  final List<String> calls = <String>[];
  SocialProfile? profile;
  SharedPlaylist? shared;
  List<ActivityEntry> feed = <ActivityEntry>[];
  bool throwOnFetch = false;

  @override
  Future<List<ActivityEntry>> activityFeed({int limit = 50}) async {
    calls.add('activityFeed');
    if (throwOnFetch) throw Exception('offline');
    return feed;
  }

  @override
  Future<SharedPlaylist?> fetchSharedPlaylist(String shareId) async {
    calls.add('fetchSharedPlaylist');
    if (throwOnFetch) throw Exception('offline');
    return shared;
  }

  @override
  Future<SocialProfile?> fetchProfile(String userId) async {
    calls.add('fetchProfile');
    if (throwOnFetch) throw Exception('offline');
    return profile;
  }

  @override
  Future<void> follow(String userId) async => calls.add('follow');

  @override
  Future<List<String>> following() async {
    calls.add('following');
    return <String>['u1'];
  }

  @override
  Future<void> publishPlaylist(SharedPlaylist playlist) async {
    calls.add('publishPlaylist');
    shared = playlist;
  }

  @override
  Future<void> publishProfile(SocialProfile newProfile) async {
    calls.add('publishProfile');
    profile = newProfile;
  }

  @override
  Future<void> unfollow(String userId) async => calls.add('unfollow');

  @override
  Future<void> unpublishPlaylist(String shareId) async {
    calls.add('unpublishPlaylist');
  }
}

void main() {
  group('SocialFeatureFlags', () {
    test('everything is off by default', () {
      const flags = SocialFeatureFlags();
      expect(flags.enabled, isFalse);
      expect(flags.canPublishProfile, isFalse);
      expect(flags.canSharePlaylists, isFalse);
      expect(flags.canFollow, isFalse);
      expect(flags.canShowFeed, isFalse);
    });

    test('a sub-feature stays off while the master switch is off', () {
      const flags = SocialFeatureFlags(
        publicProfile: true,
        playlistSharing: true,
        following: true,
        activityFeed: true,
      );
      expect(flags.canPublishProfile, isFalse);
      expect(flags.canSharePlaylists, isFalse);
      expect(flags.canFollow, isFalse);
      expect(flags.canShowFeed, isFalse);
    });

    test('sub-features activate once the master switch is on', () {
      const flags = SocialFeatureFlags(
        enabled: true,
        publicProfile: true,
        playlistSharing: true,
      );
      expect(flags.canPublishProfile, isTrue);
      expect(flags.canSharePlaylists, isTrue);
      expect(flags.canFollow, isFalse);
    });

    test('round-trips through JSON', () {
      const flags = SocialFeatureFlags(
        enabled: true,
        publicProfile: true,
        activityFeed: true,
      );
      final restored = SocialFeatureFlags.fromJson(flags.toJson());
      expect(restored.enabled, isTrue);
      expect(restored.publicProfile, isTrue);
      expect(restored.activityFeed, isTrue);
      expect(restored.following, isFalse);
    });

    test('a corrupt blob decodes to null so defaults apply', () {
      expect(SocialFeatureFlags.tryDecode('not json'), isNull);
      expect(SocialFeatureFlags.tryDecode(''), isNull);
      expect(SocialFeatureFlags.tryDecode(null), isNull);
    });
  });

  group('SocialSettings', () {
    test('reads disabled flags when nothing is stored', () async {
      final settings = SocialSettings(_MemoryStore());
      expect((await settings.read()).enabled, isFalse);
    });

    test('disabling clears every sub-flag', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(
        const SocialFeatureFlags(
          enabled: true,
          publicProfile: true,
          following: true,
        ),
      );

      final flags = await settings.setEnabled(false);

      expect(flags.enabled, isFalse);
      expect(flags.publicProfile, isFalse);
      expect(flags.following, isFalse);
    });

    test('re-enabling preserves previously chosen sub-flags', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(
        const SocialFeatureFlags(enabled: false, publicProfile: true),
      );
      final flags = await settings.setEnabled(true);
      expect(flags.enabled, isTrue);
      expect(flags.publicProfile, isTrue);
    });
  });

  group('ProfileSystem', () {
    test('returns null and makes no request while disabled', () async {
      final backend = _RecordingBackend()
        ..profile = const SocialProfile(userId: 'u', handle: 'ada');
      final system = ProfileSystem(
        settings: SocialSettings(_MemoryStore()),
        backend: backend,
        cache: _MemoryCache(),
      );

      expect(await system.profile('u'), isNull);
      expect(backend.calls, isEmpty);
    });

    test('fetches and caches when enabled', () async {
      final store = _MemoryStore();
      final settings = SocialSettings(store);
      await settings.write(const SocialFeatureFlags(enabled: true));

      final cache = _MemoryCache();
      final backend = _RecordingBackend()
        ..profile = const SocialProfile(userId: 'u', handle: 'ada');
      final system =
          ProfileSystem(settings: settings, backend: backend, cache: cache);

      final profile = await system.profile('u');

      expect(profile!.handle, 'ada');
      expect(cache.entries.containsKey('profile:u'), isTrue);
    });

    test('falls back to the cache when the backend is unreachable', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(const SocialFeatureFlags(enabled: true));

      final cache = _MemoryCache();
      await cache.write(
        'profile:u',
        const SocialProfile(userId: 'u', handle: 'cached').toJson(),
      );
      final backend = _RecordingBackend()..throwOnFetch = true;
      final system =
          ProfileSystem(settings: settings, backend: backend, cache: cache);

      expect((await system.profile('u'))!.handle, 'cached');
    });

    test('publishing requires the publicProfile flag', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(const SocialFeatureFlags(enabled: true));
      final backend = _RecordingBackend();
      final system = ProfileSystem(
        settings: settings,
        backend: backend,
        cache: _MemoryCache(),
      );

      const profile = SocialProfile(userId: 'u', handle: 'ada');
      expect(await system.publish(profile), isFalse);
      expect(backend.calls, isEmpty);

      await settings.write(
        const SocialFeatureFlags(enabled: true, publicProfile: true),
      );
      expect(await system.publish(profile), isTrue);
      expect(backend.calls, contains('publishProfile'));
    });

    test('normalizes handles and rejects unusable ones', () {
      expect(ProfileSystem.normalizeHandle('Ada Lovelace'), 'ada_lovelace');
      expect(ProfileSystem.normalizeHandle('  __ada__  '), 'ada');
      expect(ProfileSystem.normalizeHandle('a!!!b'), 'a_b');
      expect(ProfileSystem.normalizeHandle('ab'), isNull);
      expect(ProfileSystem.normalizeHandle('x' * 31), isNull);
    });
  });

  group('PlaylistSharing', () {
    Future<SocialSettings> enabledSettings() async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(
        const SocialFeatureFlags(enabled: true, playlistSharing: true),
      );
      return settings;
    }

    test('returns null while sharing is disabled', () async {
      final sharing = PlaylistSharing(
        settings: SocialSettings(_MemoryStore()),
        backend: _RecordingBackend(),
        cache: _MemoryCache(),
      );
      expect(
        await sharing.share(playlistId: 'p', ownerId: 'o', title: 'T'),
        isNull,
      );
    });

    test('produces a deterministic, reusable share id', () async {
      final first = PlaylistSharing.buildShareId(
        playlistId: 'p',
        ownerId: 'o',
      );
      final second = PlaylistSharing.buildShareId(
        playlistId: 'p',
        ownerId: 'o',
      );
      expect(first, second);
      expect(
        first,
        isNot(PlaylistSharing.buildShareId(playlistId: 'p', ownerId: 'other')),
      );
    });

    test('shares, caches and publishes', () async {
      final cache = _MemoryCache();
      final backend = _RecordingBackend();
      final sharing = PlaylistSharing(
        settings: await enabledSettings(),
        backend: backend,
        cache: cache,
      );

      final shared = await sharing.share(
        playlistId: 'p',
        ownerId: 'o',
        title: 'Road trip',
        trackCount: 12,
        mode: PlaylistShareMode.collaborate,
      );

      expect(shared!.title, 'Road trip');
      expect(shared.isCollaborative, isTrue);
      expect(backend.calls, contains('publishPlaylist'));
      expect(cache.entries.containsKey('share:${shared.shareId}'), isTrue);
    });

    test('a backend outage still yields a usable local link', () async {
      final backend = _RecordingBackend();
      final sharing = PlaylistSharing(
        settings: await enabledSettings(),
        backend: _ThrowingPublishBackend(backend),
        cache: _MemoryCache(),
      );

      final shared =
          await sharing.share(playlistId: 'p', ownerId: 'o', title: 'T');
      expect(shared, isNotNull);
      expect(shared!.link.scheme, 'spotiflac');
    });

    test('builds and parses spotiflac share links', () {
      final shared = SharedPlaylist(
        shareId: 'abc123',
        playlistId: 'p',
        ownerId: 'o',
        title: 'T',
        sharedAt: DateTime.utc(2026),
      );
      expect(shared.link.toString(), 'spotiflac://playlist/shared/abc123');
      expect(SharedPlaylist.shareIdFromLink(shared.link), 'abc123');
    });

    test('rejects links that are not share links', () {
      expect(
        SharedPlaylist.shareIdFromLink(Uri.parse('https://example.com/x')),
        isNull,
      );
      expect(
        SharedPlaylist.shareIdFromLink(Uri.parse('spotiflac://track/1')),
        isNull,
      );
      expect(
        SharedPlaylist.shareIdFromLink(Uri.parse('spotiflac://playlist/x/1')),
        isNull,
      );
    });

    test('resolves a link back to the shared playlist', () async {
      final cache = _MemoryCache();
      final sharing = PlaylistSharing(
        settings: await enabledSettings(),
        backend: null,
        cache: cache,
      );
      final shared =
          await sharing.share(playlistId: 'p', ownerId: 'o', title: 'T');

      final resolved = await sharing.resolveLink(shared!.link);
      expect(resolved!.playlistId, 'p');
    });
  });

  group('FollowSystem', () {
    test('is inert while disabled', () async {
      final backend = _RecordingBackend();
      final follow = FollowSystem(
        settings: SocialSettings(_MemoryStore()),
        backend: backend,
      );

      expect(await follow.follow('u'), isFalse);
      expect(await follow.following(), isEmpty);
      expect(backend.calls, isEmpty);
    });

    test('delegates to the backend when enabled', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(
        const SocialFeatureFlags(enabled: true, following: true),
      );
      final backend = _RecordingBackend();
      final follow = FollowSystem(settings: settings, backend: backend);

      expect(await follow.follow('u'), isTrue);
      expect(await follow.following(), <String>['u1']);
      expect(backend.calls, contains('follow'));
    });
  });

  group('ActivityFeed', () {
    ActivityEntry entry(String id, DateTime at) => ActivityEntry(
      entryId: id,
      actorId: 'a',
      kind: ActivityKind.playedTrack,
      subject: id,
      occurredAt: at,
    );

    test('is empty while disabled', () async {
      final feed = ActivityFeed(
        settings: SocialSettings(_MemoryStore()),
        backend: _RecordingBackend()
          ..feed = <ActivityEntry>[entry('a', DateTime.utc(2026))],
        cache: _MemoryCache(),
      );
      expect(await feed.entries(), isEmpty);
    });

    test('sorts newest first', () {
      final sorted = ActivityFeed.sortNewestFirst(<ActivityEntry>[
        entry('old', DateTime.utc(2025)),
        entry('new', DateTime.utc(2026)),
      ]);
      expect(sorted.map((e) => e.entryId), <String>['new', 'old']);
    });

    test('falls back to the cached feed when the backend fails', () async {
      final settings = SocialSettings(_MemoryStore());
      await settings.write(
        const SocialFeatureFlags(enabled: true, activityFeed: true),
      );
      final cache = _MemoryCache();
      await cache.write('feed:home', <String, Object?>{
        'entries': <Object?>[entry('cached', DateTime.utc(2026)).toJson()],
      });

      final feed = ActivityFeed(
        settings: settings,
        backend: _RecordingBackend()..throwOnFetch = true,
        cache: cache,
      );

      expect((await feed.entries()).single.entryId, 'cached');
    });
  });

  group('model parsing', () {
    test('SharedPlaylist round-trips through JSON', () {
      final original = SharedPlaylist(
        shareId: 's',
        playlistId: 'p',
        ownerId: 'o',
        title: 'T',
        description: 'D',
        trackCount: 3,
        mode: PlaylistShareMode.collaborate,
        sharedAt: DateTime.utc(2026),
        collaborators: const <String>['u1', 'u2'],
      );
      final restored = SharedPlaylist.tryParse(original.toJson())!;
      expect(restored.shareId, 's');
      expect(restored.mode, PlaylistShareMode.collaborate);
      expect(restored.collaborators, <String>['u1', 'u2']);
    });

    test('records without an id are rejected', () {
      expect(SharedPlaylist.tryParse(const <String, Object?>{}), isNull);
      expect(SocialProfile.tryParse(const <String, Object?>{}), isNull);
      expect(ActivityEntry.tryParse(const <String, Object?>{}), isNull);
    });

    test('unknown enum values fall back to a safe default', () {
      expect(PlaylistShareMode.parse('nonsense'), PlaylistShareMode.view);
      expect(ActivityKind.parse('nonsense'), ActivityKind.playedTrack);
    });
  });
}

/// Backend whose publish always fails, to prove sharing degrades locally.
class _ThrowingPublishBackend implements SocialBackend {
  _ThrowingPublishBackend(this._inner);

  final SocialBackend _inner;

  @override
  Future<void> publishPlaylist(SharedPlaylist playlist) async {
    throw Exception('offline');
  }

  @override
  Future<List<ActivityEntry>> activityFeed({int limit = 50}) =>
      _inner.activityFeed(limit: limit);

  @override
  Future<SharedPlaylist?> fetchSharedPlaylist(String shareId) =>
      _inner.fetchSharedPlaylist(shareId);

  @override
  Future<SocialProfile?> fetchProfile(String userId) =>
      _inner.fetchProfile(userId);

  @override
  Future<void> follow(String userId) => _inner.follow(userId);

  @override
  Future<List<String>> following() => _inner.following();

  @override
  Future<void> publishProfile(SocialProfile profile) =>
      _inner.publishProfile(profile);

  @override
  Future<void> unfollow(String userId) => _inner.unfollow(userId);

  @override
  Future<void> unpublishPlaylist(String shareId) =>
      _inner.unpublishPlaylist(shareId);
}
