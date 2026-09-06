import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/synced_lyrics_scroll.dart';

void main() {
  test('symmetric padding lets the final lyric line reach center', () {
    const viewport = 500.0;
    const lineExtent = 64.0;
    const lineCount = 20;
    final padding = syncedLyricsCenterPadding(
      viewportDimension: viewport,
      estimatedLineExtent: lineExtent,
    );
    final contentExtent = (padding * 2) + (lineCount * lineExtent);
    final maxScrollExtent = contentExtent - viewport;
    final lastLineOffset = syncedLyricsEstimatedOffset(
      index: lineCount - 1,
      estimatedLineExtent: lineExtent,
    );

    expect(padding, 218);
    expect(lastLineOffset, maxScrollExtent);
  });

  test('small viewports retain minimum breathing room', () {
    expect(
      syncedLyricsCenterPadding(viewportDimension: 80, estimatedLineExtent: 64),
      24,
    );
  });

  test('advances at the exact next line boundary', () {
    const starts = [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 6),
    ];

    expect(
      syncedLyricsDueLineIndex(
        lineStarts: starts,
        currentIndex: 0,
        position: const Duration(milliseconds: 2999),
      ),
      0,
    );
    expect(
      syncedLyricsDueLineIndex(
        lineStarts: starts,
        currentIndex: 0,
        position: const Duration(seconds: 3),
      ),
      2,
    );
  });

  group('smooth timed lyric highlight', () {
    test('interpolates position only while playback is advancing', () {
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: const Duration(seconds: 10),
          elapsedSinceAnchor: const Duration(milliseconds: 250),
          isPlaying: true,
        ),
        const Duration(milliseconds: 10250),
      );
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: const Duration(seconds: 10),
          elapsedSinceAnchor: const Duration(milliseconds: 250),
          isPlaying: false,
        ),
        const Duration(seconds: 10),
      );
    });

    test('blends small clock corrections and applies seeks immediately', () {
      expect(
        reconcileSyncedLyricsPosition(
          predictedPosition: const Duration(milliseconds: 1000),
          reportedPosition: const Duration(milliseconds: 1100),
        ),
        const Duration(milliseconds: 1025),
      );
      expect(
        reconcileSyncedLyricsPosition(
          predictedPosition: const Duration(seconds: 1),
          reportedPosition: const Duration(seconds: 5),
        ),
        const Duration(seconds: 5),
      );
    });

    test('calculates continuous progress inside a timed segment', () {
      const start = Duration(seconds: 2);
      const end = Duration(seconds: 3);

      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 1500),
          start: start,
          end: end,
        ),
        0,
      );
      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 2250),
          start: start,
          end: end,
        ),
        0.25,
      );
      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 3500),
          start: start,
          end: end,
        ),
        1,
      );
    });

    test('moves the reveal boundary from left to right', () {
      expect(
        syncedLyricsLeftToRightBoundary(left: 10, right: 110, progress: 0),
        10,
      );
      expect(
        syncedLyricsLeftToRightBoundary(left: 10, right: 110, progress: 0.5),
        60,
      );
      expect(
        syncedLyricsLeftToRightBoundary(left: 10, right: 110, progress: 1),
        110,
      );
    });
  });
}
