import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/theme/app_theme.dart';
import 'package:spotiflac_android/ui/widgets/liquid_glass_container.dart';
import 'package:spotiflac_android/ui/widgets/liquid_glass_player_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: TickerMode(
          enabled: false,
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('LiquidGlassContainer', () {
    testWidgets('renders its child and the gradient border', (tester) async {
      await tester.pumpWidget(
        host(
          const LiquidGlassContainer(
            enableBlur: false,
            child: Text('glass card'),
          ),
        ),
      );
      expect(find.text('glass card'), findsOneWidget);
      expect(find.byType(LiquidGlassContainer), findsOneWidget);
    });

    testWidgets('LiquidGlassBackground renders descendants', (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            height: 120,
            child: LiquidGlassBackground(child: Text('aurora above glows')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('aurora above glows'), findsOneWidget);
    });
  });

  group('LiquidGlassPlayerSheet', () {
    const track = Track(
      id: 't1',
      name: 'Test Song',
      artistName: 'Test Artist',
      albumName: 'Test Album',
      duration: 210,
    );

    Future<void> pumpSheet(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(const LiquidGlassPlayerSheet(track: track)),
      );
      await tester.pump();
    }

    testWidgets('shows all eight provider chips and the FLAC button', (
      tester,
    ) async {
      await pumpSheet(tester);

      expect(find.text('STREAM PROVIDER'), findsOneWidget);
      expect(find.text('OFFLINE MODE'), findsOneWidget);
      expect(
        find.text('Download lossless FLAC for offline'),
        findsOneWidget,
      );
      for (final name in [
        'Spotify',
        'YT Music',
        'Apple',
        'Tidal',
        'Qobuz',
        'Deezer',
        'Amazon',
        'SoundCloud',
      ]) {
        expect(find.text(name), findsOneWidget, reason: 'chip $name missing');
      }
    });

    testWidgets('exposes a lossless FLAC download action label', (
      tester,
    ) async {
      await pumpSheet(tester);

      expect(
        find.text('Download lossless FLAC for offline'),
        findsOneWidget,
      );
    });
  });
}
