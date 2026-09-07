import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/social/social_models.dart';
import 'package:spotiflac_android/services/audiobook/audiobook.dart';
import 'package:spotiflac_android/services/podcasts/podcasts.dart';
import 'package:spotiflac_android/services/social/social.dart';

void main() {
  group('OpmlCodec', () {
    const codec = OpmlCodec();

    test('parses rss outlines and round-trips export', () {
      const xml = '''
<?xml version="1.0"?>
<opml version="2.0">
  <body>
    <outline type="rss" text="ATP" title="ATP" xmlUrl="https://atp.fm/rss"/>
    <outline type="rss" text="Empty"/>
  </body>
</opml>
''';
      final outlines = codec.parse(xml);
      expect(outlines.single.xmlUrl, 'https://atp.fm/rss');
      expect(outlines.single.displayTitle, 'ATP');
      final subs = codec.toSubscriptions(
        outlines,
        now: DateTime.utc(2026, 9, 7),
      );
      final exported = codec.export(subs);
      expect(exported, contains('xmlUrl="https://atp.fm/rss"'));
      expect(codec.parse(exported), hasLength(1));
    });
  });

  group('SleepTimer', () {
    test('fires after the deadline and can cancel', () async {
      final clock = <DateTime>[DateTime.utc(2026, 9, 7, 12)];
      var fired = 0;
      final timer = SleepTimer(
        duration: const Duration(minutes: 15),
        clock: () => clock.last,
        onFire: () async {
          fired++;
        },
      );
      timer.arm(now: clock.last);
      expect(timer.isArmed, isTrue);
      expect(
        timer.remaining(now: clock.last),
        const Duration(minutes: 15),
      );
      clock.add(clock.last.add(const Duration(minutes: 16)));
      expect(await timer.tick(now: clock.last), isTrue);
      expect(fired, 1);
      expect(timer.hasFired, isTrue);

      final other = SleepTimer(clock: () => clock.last);
      other.arm(now: clock.last);
      other.cancel();
      expect(await other.tick(now: clock.last.add(const Duration(hours: 1))), isFalse);
    });

    test('end-of-episode mode waits for the flag', () async {
      final timer = SleepTimer(mode: SleepTimerMode.endOfEpisode);
      timer.arm(mode: SleepTimerMode.endOfEpisode);
      expect(await timer.tick(), isFalse);
      expect(await timer.tick(episodeEnded: true), isTrue);
    });
  });

  group('PodcastNotificationPolicy', () {
    test('respects notifyNew', () {
      const policy = PodcastNotificationPolicy();
      final sub = PodcastSubscription(
        feedUrl: 'https://a/rss',
        title: 'Show',
        addedAt: DateTime.utc(2026),
        notifyNew: false,
      );
      final episode = PodcastEpisode(
        episodeKey: 'k',
        feedUrl: sub.feedUrl,
        guid: 'g',
        title: 'Ep',
        audioUrl: 'https://a/e.mp3',
        addedAt: DateTime.utc(2026),
      );
      final refresh = PodcastRefreshResult(
        feedUrl: sub.feedUrl,
        newEpisodes: <PodcastEpisode>[episode],
        totalEpisodes: 1,
      );
      expect(policy.alertsFor(subscription: sub, refresh: refresh), isEmpty);
      expect(
        policy.alertsFor(
          subscription: sub.copyWith(notifyNew: true),
          refresh: refresh,
        ),
        hasLength(1),
      );
    });
  });

  group('Audiobook', () {
    test('chapters, resume, bookmarks and LWW merge', () {
      const chapters = <AudiobookChapter>[
        AudiobookChapter(
          id: 'c1',
          title: 'One',
          start: Duration.zero,
          end: Duration(minutes: 10),
          index: 0,
        ),
        AudiobookChapter(
          id: 'c2',
          title: 'Two',
          start: Duration(minutes: 10),
          end: Duration(minutes: 20),
          index: 1,
        ),
      ];
      var book = Audiobook(
        id: 'b1',
        title: 'Dune',
        author: 'Herbert',
        filePath: '/books/dune.m4b',
        duration: const Duration(minutes: 20),
        chapters: chapters,
        position: Duration.zero,
        updatedAt: DateTime.utc(2026, 9, 1),
      );
      expect(book.chapterAt(const Duration(minutes: 12))!.id, 'c2');
      expect(playableFromAudiobook(book).playbackMode, 'audiobook');

      final library = AudiobookLibrary(clock: () => DateTime.utc(2026, 9, 7));
      library.upsert(book);
      book = library.saveProgress('b1', const Duration(minutes: 12));
      expect(book.progress, closeTo(0.6, 0.01));
      book = library.addBookmark(
        'b1',
        bookmarkId: 'm1',
        position: const Duration(minutes: 12),
        note: 'sandworm',
      );
      expect(book.bookmarks.single.chapterId, 'c2');

      const merge = AudiobookProgressMerge();
      final remote = book.copyWith(
        position: const Duration(minutes: 15),
        updatedAt: DateTime.utc(2026, 9, 8),
        bookmarks: const <AudiobookBookmark>[
          AudiobookBookmark(
            id: 'm2',
            position: Duration(minutes: 3),
            createdAt: DateTime.utc(2026, 9, 8),
          ),
        ],
      );
      final merged = merge.merge(book, remote);
      expect(merged.position, const Duration(minutes: 15));
      expect(merged.bookmarks.map((m) => m.id), containsAll(<String>['m1', 'm2']));
    });
  });

  group('Social privacy', () {
    test('new flags default off and private session wins', () {
      const flags = SocialFeatureFlags();
      expect(flags.collaborativePlaylists, isFalse);
      expect(flags.canShowFriendActivity, isFalse);
      const open = SocialFeatureFlags(
        enabled: true,
        friendActivity: true,
        realtimeSync: true,
        collaborativePlaylists: true,
      );
      expect(open.canShowFriendActivity, isTrue);
      expect(open.canUseRealtime, isTrue);
      const stealth = SocialFeatureFlags(
        enabled: true,
        friendActivity: true,
        realtimeSync: true,
        collaborativePlaylists: true,
        privateSession: true,
      );
      final decision = const SocialPrivacyPolicy(flags: stealth).evaluate();
      expect(decision.publishActivity, isFalse);
      expect(decision.allowRealtime, isFalse);
      expect(decision.allowCollaborate, isFalse);

      const publisher = FriendActivityPublisher(
        privacy: SocialPrivacyPolicy(flags: stealth),
      );
      expect(
        publisher.publish(
          FriendActivityEvent(
            userId: 'u',
            handle: 'ada',
            trackTitle: 'Nightcall',
            at: DateTime.utc(2026),
          ),
        ),
        isNull,
      );
    });
  });
}
