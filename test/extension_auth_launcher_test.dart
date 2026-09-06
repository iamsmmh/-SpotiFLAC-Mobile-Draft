import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/extension_auth_launcher.dart';

void main() {
  test('extracts the extension that raised a verification challenge', () {
    expect(
      extensionIdFromVerificationError(
        "verification_required: extension 'tidal-web' needs verification",
        const ['amazon-web', 'tidal-web'],
      ),
      'tidal-web',
    );
  });

  test('prefers the longest known extension id in legacy errors', () {
    expect(
      extensionIdFromVerificationError(
        'qobuz-web verification_required',
        const ['qobuz', 'qobuz-web'],
      ),
      'qobuz-web',
    );
  });

  test('verification wait can be cancelled before foreground resume', () async {
    final foreground = Completer<void>();
    final cancellation = Completer<void>();
    final result = openVerificationAndAwaitGrant(
      'tidal-web',
      browserMode: 'in_app_first',
      awaitForeground: (_) => foreground.future,
      cancellationSignal: cancellation.future,
    );

    cancellation.complete();

    expect(await result.timeout(const Duration(seconds: 1)), isFalse);
  });
}
