import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';
import 'package:spotiflac_android/widgets/synced_lyrics_viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ParsedLyrics lyrics() => LyricsParser.parse('''
[00:01.00]First line
[00:02.00]Second line
[00:03.00]Third line
''');

  Widget host({
    required ParsedLyrics parsed,
    required Duration position,
    required ValueChanged<Duration> onSeek,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: SyncedLyricsViewer(
            lyrics: parsed,
            position: position,
            playing: false,
            loading: false,
            onSeek: onSeek,
          ),
        ),
      ),
    );
  }

  testWidgets('renders every lyric line', (tester) async {
    await tester.pumpWidget(
      host(
        parsed: lyrics(),
        position: Duration.zero,
        onSeek: (_) {},
      ),
    );
    await tester.pump();

    expect(find.text('First line'), findsOneWidget);
    expect(find.text('Second line'), findsOneWidget);
    expect(find.text('Third line'), findsOneWidget);
  });

  testWidgets('tapping a line seeks to its timestamp', (tester) async {
    Duration? seeked;
    await tester.pumpWidget(
      host(
        parsed: lyrics(),
        position: Duration.zero,
        onSeek: (t) => seeked = t,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Second line'));
    await tester.pump();

    expect(seeked, const Duration(seconds: 2));
  });

  testWidgets('renders nothing for empty lyrics', (tester) async {
    await tester.pumpWidget(
      host(
        parsed: ParsedLyrics.empty,
        position: Duration.zero,
        onSeek: (_) {},
      ),
    );
    await tester.pump();

    expect(find.byType(SyncedLyricsViewer), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  test('activeIndexFor returns the due line for a position', () {
    final parsed = lyrics();
    expect(
      SyncedLyricsViewer.activeIndexFor(
        parsed.lines,
        const Duration(milliseconds: 1500),
      ),
      0,
    );
    expect(
      SyncedLyricsViewer.activeIndexFor(
        parsed.lines,
        const Duration(seconds: 3),
      ),
      2,
    );
    expect(
      SyncedLyricsViewer.activeIndexFor(
        parsed.lines,
        const Duration(milliseconds: 500),
      ),
      -1,
    );
  });
}
