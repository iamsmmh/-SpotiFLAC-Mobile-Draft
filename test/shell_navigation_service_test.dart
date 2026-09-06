import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/services/shell_navigation_service.dart';
import 'package:spotiflac_android/widgets/view_queue_snackbar_action.dart';

void main() {
  group('ShellNavigationService tab requests', () {
    test('forwards a named tab request to the registered shell', () {
      final owner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );

      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => requestedTab = tab,
      );

      expect(ShellNavigationService.requestTab(ShellTab.library), isTrue);
      expect(requestedTab, ShellTab.library);
    });

    test('does not remove a newer shell handler', () {
      final oldOwner = Object();
      final currentOwner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () =>
            ShellNavigationService.unregisterTabSelectionHandler(currentOwner),
      );

      ShellNavigationService.registerTabSelectionHandler(
        owner: oldOwner,
        handler: (_) {},
      );
      ShellNavigationService.registerTabSelectionHandler(
        owner: currentOwner,
        handler: (tab) => requestedTab = tab,
      );

      ShellNavigationService.unregisterTabSelectionHandler(oldOwner);

      expect(ShellNavigationService.requestTab(ShellTab.settings), isTrue);
      expect(requestedTab, ShellTab.settings);
    });

    test('reports when no shell can handle the request', () {
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (_) {},
      );
      ShellNavigationService.unregisterTabSelectionHandler(owner);

      expect(ShellNavigationService.requestTab(ShellTab.library), isFalse);
    });

    testWidgets('View Queue snackbar action requests the Library tab', (
      tester,
    ) async {
      final owner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => requestedTab = tab,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => buildViewQueueSnackBarAction(context),
            ),
          ),
        ),
      );

      await tester.tap(find.text('View Queue'));

      expect(requestedTab, ShellTab.library);
    });
  });
}
