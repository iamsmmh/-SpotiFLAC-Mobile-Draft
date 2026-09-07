/// Audiobook library models (Phase 10).
///
/// Chapters, resume points, bookmarks and progress. Pure data so the player
/// and the cloud-sync payload share one shape.
library;

/// One chapter inside an audiobook.
class AudiobookChapter {
  const AudiobookChapter({
    required this.id,
    required this.title,
    required this.start,
    this.end,
    this.index = 0,
  });

  final String id;
  final String title;
  final Duration start;
  final Duration? end;
  final int index;

  Duration get duration {
    final until = end;
    if (until == null) return Duration.zero;
    final span = until - start;
    return span.isNegative ? Duration.zero : span;
  }

  bool contains(Duration position) {
    if (position < start) return false;
    final until = end;
    if (until == null) return true;
    return position < until;
  }
}

/// A user-dropped bookmark.
class AudiobookBookmark {
  const AudiobookBookmark({
    required this.id,
    required this.position,
    required this.createdAt,
    this.note = '',
    this.chapterId,
  });

  final String id;
  final Duration position;
  final DateTime createdAt;
  final String note;
  final String? chapterId;
}

/// One audiobook in the library.
class Audiobook {
  const Audiobook({
    required this.id,
    required this.title,
    this.author = '',
    this.narrator = '',
    this.coverUrl,
    this.filePath = '',
    this.duration = Duration.zero,
    this.chapters = const <AudiobookChapter>[],
    this.bookmarks = const <AudiobookBookmark>[],
    this.position = Duration.zero,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String author;
  final String narrator;
  final String? coverUrl;
  final String filePath;
  final Duration duration;
  final List<AudiobookChapter> chapters;
  final List<AudiobookBookmark> bookmarks;
  final Duration position;
  final DateTime? updatedAt;

  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final ratio = position.inMilliseconds / total;
    if (ratio.isNaN || ratio <= 0) return 0;
    return ratio >= 1 ? 1 : ratio;
  }

  AudiobookChapter? chapterAt(Duration position) {
    for (final chapter in chapters) {
      if (chapter.contains(position)) return chapter;
    }
    return chapters.isEmpty ? null : chapters.last;
  }

  Audiobook copyWith({
    Duration? position,
    List<AudiobookBookmark>? bookmarks,
    DateTime? updatedAt,
  }) {
    return Audiobook(
      id: id,
      title: title,
      author: author,
      narrator: narrator,
      coverUrl: coverUrl,
      filePath: filePath,
      duration: duration,
      chapters: chapters,
      bookmarks: bookmarks ?? this.bookmarks,
      position: position ?? this.position,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toSyncPayload() => <String, Object?>{
        'id': id,
        'positionMs': position.inMilliseconds,
        'updatedAt': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
        'bookmarks': <Map<String, Object?>>[
          for (final mark in bookmarks)
            <String, Object?>{
              'id': mark.id,
              'positionMs': mark.position.inMilliseconds,
              'note': mark.note,
              'chapterId': mark.chapterId,
              'createdAt': mark.createdAt.toUtc().toIso8601String(),
            },
        ],
      };
}

/// Last-write-wins merge for resume + bookmark union.
class AudiobookProgressMerge {
  const AudiobookProgressMerge();

  Audiobook merge(Audiobook local, Audiobook remote) {
    final localAt = local.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final remoteAt = remote.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final newer = remoteAt.isAfter(localAt) ? remote : local;
    final older = identical(newer, remote) ? local : remote;
    final byId = <String, AudiobookBookmark>{
      for (final mark in older.bookmarks) mark.id: mark,
      for (final mark in newer.bookmarks) mark.id: mark,
    };
    final merged = byId.values.toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return newer.copyWith(bookmarks: List<AudiobookBookmark>.unmodifiable(merged));
  }
}
