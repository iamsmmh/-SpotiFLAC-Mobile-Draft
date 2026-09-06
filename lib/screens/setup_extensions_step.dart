import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/l10n/staged_strings.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/repo_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SetupExtensionsStep');

enum _SetupExtensionsPhase { idle, working, done, error }

/// Human summary of a recommended-install pass (logging + tests).
String summarizeRecommendedInstall(RecommendedInstallResult result) {
  final ready = result.installed.length + result.alreadyPresent.length;
  final total = ready + result.unavailable.length + result.failed.length;
  return '$ready/$total ready '
      '(new: ${result.installed.length}, '
      'kept: ${result.alreadyPresent.length}, '
      'missing: ${result.unavailable.length}, '
      'failed: ${result.failed.length})';
}

/// Final first-run setup step: connects the (default) extension registry and
/// one-tap installs the recommended starter set.
///
/// The step never blocks setup: the parent wizard always allows proceeding,
/// and everything here can be redone later from the Store tab.
class SetupExtensionsStep extends ConsumerStatefulWidget {
  const SetupExtensionsStep({super.key});

  @override
  ConsumerState<SetupExtensionsStep> createState() =>
      _SetupExtensionsStepState();
}

class _SetupExtensionsStepState extends ConsumerState<SetupExtensionsStep> {
  _SetupExtensionsPhase _phase = _SetupExtensionsPhase.idle;
  String _status = '';
  RecommendedInstallResult? _result;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_started || !mounted) return;
    _started = true;
    setState(() {
      _phase = _SetupExtensionsPhase.working;
      _status = StagedStrings.setupExtensionsConnecting;
    });

    try {
      final repo = ref.read(repoProvider.notifier);
      if (!ref.read(repoProvider).isInitialized) {
        final cacheDir = await getApplicationCacheDirectory();
        await repo.initialize(cacheDir.path);
      } else if (!ref.read(repoProvider).hasRegistryUrl) {
        // Initialized but registry-less (e.g. user removed it): refresh in
        // case the listing went stale, then continue gracefully.
        await repo.refresh();
      }

      // Extensions load at app startup; wait for them so the
      // already-installed check inside installRecommended is accurate.
      await ref.read(extensionProvider.notifier).waitForInitialization();

      if (!mounted) return;
      final registryEmpty = ref.read(repoProvider).extensions.isEmpty;
      if (registryEmpty) {
        setState(() {
          _phase = _SetupExtensionsPhase.error;
          _status = StagedStrings.setupExtensionsOffline;
        });
        return;
      }

      setState(() {
        _status = StagedStrings.setupExtensionsInstalling;
      });

      final tempDir = await getTemporaryDirectory();
      final appDir = await getApplicationDocumentsDirectory();
      final result = await repo.installRecommended(
        tempDir: tempDir.path,
        extensionsDir: '${appDir.path}/extensions',
      );
      _log.i(
        'Setup recommended install: ${summarizeRecommendedInstall(result)}',
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _SetupExtensionsPhase.done;
        _status = result.allReady
            ? StagedStrings.setupExtensionsInstalled
            : StagedStrings.setupExtensionsPartial;
      });
    } catch (e) {
      _log.w('Setup extensions step failed: $e');
      if (!mounted) return;
      setState(() {
        _phase = _SetupExtensionsPhase.error;
        _status = StagedStrings.setupExtensionsOffline;
      });
    }
  }

  void _retry() {
    _started = false;
    _result = null;
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final iconPadding = (shortestSide * 0.06).clamp(16.0, 24.0);
        final iconSize = (shortestSide * 0.12).clamp(32.0, 48.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final descriptionGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        final actionGap = (shortestSide * 0.09).clamp(20.0, 48.0);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 104),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(iconPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.extension_outlined,
                      size: iconSize,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    StagedStrings.setupExtensionsTitle,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: descriptionGap),
                  Text(
                    StagedStrings.setupExtensionsDescription,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: actionGap),
                  _buildStatusCard(colorScheme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusCard(ColorScheme colorScheme) {
    switch (_phase) {
      case _SetupExtensionsPhase.idle:
      case _SetupExtensionsPhase.working:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _status.isEmpty
                      ? StagedStrings.setupExtensionsConnecting
                      : _status,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );
      case _SetupExtensionsPhase.done:
        final result = _result;
        final ok = result?.allReady ?? true;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ok
                ? colorScheme.primaryContainer
                : colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.warning_amber_rounded,
                color: ok
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _status,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: ok
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      case _SetupExtensionsPhase.error:
        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    color: colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _status,
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text(StagedStrings.setupExtensionsRetry),
            ),
          ],
        );
    }
  }
}
