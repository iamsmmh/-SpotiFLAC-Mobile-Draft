/// Upgrade permission-diff gate.
///
/// Extensions are installed from community registries and *self-update*.
/// When a new version of an already-installed extension asks for more
/// permissions than the current one (new network hosts, storage, file,
/// plain-http), the user should see that delta before the swap replaces a
/// previously trusted install. The Go side exposes both flattened
/// permission lists on `checkExtensionUpgrade`; this file turns them into a
/// confirmation dialog that install/update flows can pass around.
library;

import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/staged_strings.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';

/// Pure diff helper: everything in [next] that is not in [current].
List<String> diffPermissions(Iterable<String> current, Iterable<String> next) {
  final currentSet = current.toSet();
  final seen = <String>{};
  final added = <String>[];
  for (final permission in next) {
    if (currentSet.contains(permission) || !seen.add(permission)) continue;
    added.add(permission);
  }
  return added;
}

/// Added permissions an upgrade candidate package ([filePath]) requests
/// over the currently installed extension. Empty for fresh installs, when
/// the version is not an upgrade, or when anything about the check fails
/// (the gate must never block installs because it is broken).
Future<List<String>> addedPermissionsForPackage(String filePath) async {
  try {
    final info = await PlatformBridge.checkExtensionUpgrade(filePath);
    if (info['is_installed'] != true) return const <String>[];
    final current = (info['current_permissions'] as List? ?? const [])
        .map((e) => '$e');
    final next =
        (info['new_permissions'] as List? ?? const []).map((e) => '$e');
    return diffPermissions(current, next);
  } catch (_) {
    return const <String>[];
  }
}

/// A confirmer callback for the install/update flows: asks the user to
/// approve [added] permissions, returning false only when they decline.
Future<bool> Function(List<String> addedPermissions) buildPermissionConfirmer(
  BuildContext context,
) {
  return (added) async {
    if (added.isEmpty || !context.mounted) return added.isEmpty;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(StagedStrings.permDiffTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(StagedStrings.permDiffBody),
            const SizedBox(height: 8),
            for (final permission in added)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        permission,
                        style: Theme.of(dialogContext).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(StagedStrings.permDiffCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(StagedStrings.permDiffProceed),
          ),
        ],
      ),
    );
    if (confirmed != true && messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text(StagedStrings.permDiffCancelled)),
      );
    }
    return confirmed == true;
  };
}
