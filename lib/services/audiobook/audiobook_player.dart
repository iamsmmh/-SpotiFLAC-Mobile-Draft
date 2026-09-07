/// Audiobook player (Phase 10) — chapters, resume, bookmarks.
///
/// Reuses the same [PlayableMedia] currency as podcasts / music so lockscreen
/// and car controls keep working. Does not introduce a second audio pipeline.
library;

import 'package:spotiflac_android/services/audiobook/audiobook_models.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/podcasts/sleep_timer.dart';

/// Converts an audiobook into the engine's media value.
PlayableMedia playableFromAudiobook(Audiobook book) {
  return PlayableMedia(
    id: book.id,
    source: book.filePath,
    title: book.title,
    artist: book.author,
    album: book.narrator.isEmpty ? book.author : book.narrator,
    artUri: book.coverUrl,
    duration: book.duration > Duration.zero ? book.duration : null,
    playbackMode: 'audiobook',
    sourceLabel: book.author,
    providerId: 'audiobook',
  );
}

/// In-memory library + resume/bookmark helpers. Persistence is the caller's
/// job (SQLite / cloud sync); this stays hermetic for tests.
class AudiobookLibrary {
  AudiobookLibrary({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, Audiobook> _books = <String, Audiobook>{};

  List<Audiobook> get all => List<Audiobook>.unmodifiable(_books.values);

  void upsert(Audiobook book) => _books[book.id] = book;

  Audiobook? get(String id) => _books[id];

  Audiobook saveProgress(String id, Duration position) {
    final existing = _books[id];
    if (existing == null) {
      throw StateError('unknown audiobook $id');
    }
    final next = existing.copyWith(
      position: position,
      updatedAt: _clock().toUtc(),
    );
    _books[id] = next;
    return next;
  }

  Audiobook addBookmark(
    String id, {
    required String bookmarkId,
    required Duration position,
    String note = '',
  }) {
    final existing = _books[id];
    if (existing == null) {
      throw StateError('unknown audiobook $id');
    }
    final chapter = existing.chapterAt(position);
    final mark = AudiobookBookmark(
      id: bookmarkId,
      position: position,
      createdAt: _clock().toUtc(),
      note: note,
      chapterId: chapter?.id,
    );
    final next = existing.copyWith(
      bookmarks: <AudiobookBookmark>[...existing.bookmarks, mark],
      updatedAt: _clock().toUtc(),
    );
    _books[id] = next;
    return next;
  }

  Audiobook removeBookmark(String id, String bookmarkId) {
    final existing = _books[id];
    if (existing == null) {
      throw StateError('unknown audiobook $id');
    }
    final next = existing.copyWith(
      bookmarks: <AudiobookBookmark>[
        for (final mark in existing.bookmarks)
          if (mark.id != bookmarkId) mark,
      ],
      updatedAt: _clock().toUtc(),
    );
    _books[id] = next;
    return next;
  }
}

/// Drives chapter skip / resume on top of the shared handler.
class AudiobookPlayer {
  AudiobookPlayer({
    required AudiobookLibrary library,
    this.sleepTimer,
    MusicPlayerHandler? Function()? handlerLookup,
  })  : _library = library,
        _handlerLookup = handlerLookup ?? (() => musicPlayerHandler);

  final AudiobookLibrary _library;
  final SleepTimer? sleepTimer;
  final MusicPlayerHandler? Function() _handlerLookup;

  String? _currentId;

  String? get currentId => _currentId;

  Future<void> play(Audiobook book, {bool resume = true}) async {
    final handler = await initMusicPlayer();
    _currentId = book.id;
    await handler.setQueueAndPlay(<PlayableMedia>[playableFromAudiobook(book)]);
    final position = book.position;
    if (resume && position > const Duration(seconds: 3)) {
      await handler.seek(position);
    }
  }

  Future<void> seekToChapter(AudiobookChapter chapter) async {
    await _handlerLookup()?.seek(chapter.start);
    final id = _currentId;
    if (id != null) _library.saveProgress(id, chapter.start);
  }

  Future<void> reportPosition(Duration position) async {
    final id = _currentId;
    if (id == null) return;
    _library.saveProgress(id, position);
    await sleepTimer?.tick();
  }
}
