import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/screens/discovery/discovery_home_screen.dart';

/// For You (Phase 7) — now the entry point into the on-device discovery
/// engine (Phases 1–10).
///
/// This class is deliberately kept: it is the widget the tab navigator
/// constructs, and the route name `forYouTitle` is what users already see.
/// The body is [DiscoveryHomeScreen], which renders every shelf the old screen
/// produced (recently played, frequently played, discovery mix, similar
/// artists, "because you listened", trending) **plus** the new personalised
/// shelves, and it still renders the pre-existing `forYouSectionsProvider`
/// chain underneath so a configured remote recommendation provider keeps
/// working exactly as before.
class ForYouScreen extends ConsumerWidget {
  const ForYouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DiscoveryHomeScreen(title: context.l10n.forYouTitle);
  }
}
