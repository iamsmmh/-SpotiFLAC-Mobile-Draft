import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/screens/track_metadata_screen.dart';
import 'package:spotiflac_android/widgets/album_detail_header.dart';
import 'package:spotiflac_android/widgets/audio_quality_badges.dart';

void main() {
  testWidgets('metadata hero keeps technical text legible in light theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final item = DownloadHistoryItem(
      id: 'history-track',
      trackName: 'Track',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: r'Z:\missing\track.flac',
      service: 'tidal-web',
      downloadedAt: DateTime(2026),
      duration: 250,
      bitDepth: 16,
      sampleRate: 44100,
      format: 'flac',
      explicit: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TrackMetadataScreen(item: item),
        ),
      ),
    );
    await tester.pump();

    final headerMeta = find.byType(HeaderMetaRow);
    expect(headerMeta, findsOneWidget);
    expect(find.byType(ExplicitBadge), findsNWidgets(2));
    expect(find.text('Explicit'), findsNothing);
    for (final label in const ['16-bit/44.1kHz', '4:10', 'Tidal-web']) {
      final text = tester.widget<Text>(
        find.descendant(of: headerMeta, matching: find.text(label)),
      );
      expect(text.style?.color, Colors.white);
    }

    final separators = tester.widgetList<Text>(
      find.descendant(of: headerMeta, matching: find.text('•')),
    );
    expect(separators, isNotEmpty);
    expect(
      separators.every((text) => text.style?.color == Colors.white70),
      isTrue,
    );

    final durationLabel = find.text('Duration');
    final metadataRow = find
        .ancestor(of: durationLabel, matching: find.byType(Row))
        .first;
    final row = tester.widget<Row>(metadataRow);

    expect(row.crossAxisAlignment, CrossAxisAlignment.baseline);
    expect(row.textBaseline, TextBaseline.alphabetic);
  });
}
