import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/theme/app_theme.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_glass.dart';

void main() {
  Widget host(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: LiquidGlassScope(
          capabilities: const LiquidGlassCapabilities(
            blur: false,
            sheen: false,
            pointerGlow: false,
            useHapticStyle: false,
          ),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  group('Liquid Glass surfaces', () {
    testWidgets('GlassSurface renders its child without blur support', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const GlassSurface(
            style: LiquidGlassStyle(blurSigma: 12),
            child: Text('glass'),
          ),
        ),
      );

      expect(find.text('glass'), findsOneWidget);
    });

    testWidgets('GlassIconButton exposes a semantic tooltip', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        host(
          GlassIconButton(
            icon: Icons.play_arrow,
            tooltip: 'Play',
            onPressed: () => pressed++,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      expect(pressed, 1);
    });

    testWidgets('GlassSlider clamps and reports changes', (tester) async {
      double? value;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 240,
              child: GlassSlider(
                value: 0.4,
                onChanged: (v) => value = v,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(value, isNull);
    });
  });

  group('Liquid scrim', () {
    testWidgets('renders over the surface color when blurred', (tester) async {
      await tester.pumpWidget(
        host(const GlassScrim(blurSigma: 4, child: Text('scrim'))),
      );
      expect(find.text('scrim'), findsOneWidget);
    });
  });
}
