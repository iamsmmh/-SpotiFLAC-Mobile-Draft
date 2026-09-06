import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/sync_provider.dart';
import 'package:spotiflac_android/screens/settings/spotiflac_cloud_page.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Cloud sync settings page (Phase 6).
///
/// Honest by construction: with no backend adapter registered (the shipped
/// default) the page explains the architecture and offers no fake actions.
/// Registering a [CloudSyncProvider] (see `docs/CLOUD_SYNC.md`) turns every
/// control live without UI changes.
class CloudSyncPage extends ConsumerWidget {
  const CloudSyncPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(syncStateProvider);
    final backend = ref.watch(cloudSyncBackendProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.syncTitle),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        icon: Icons.dns_outlined,
                        title: 'SpotiFLAC Cloud',
                        subtitle: 'Self-hosted server, devices and backups',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => const SpotiFlacCloudPage(),
                          ),
                        ),
                      ),
                      SettingsItem(
                        icon: _statusIcon(snapshot.status),
                        title: context.l10n.syncTitle,
                        subtitle:
                            '${backend.displayName} • ${_statusLabel(context, snapshot.status)}',
                      ),
                      if (snapshot.lastSyncAt != null)
                        SettingsItem(
                          icon: Icons.schedule,
                          title: context.l10n.syncLastSync(
                            _formatTimestamp(snapshot.lastSyncAt!),
                          ),
                        ),
                      if (snapshot.pendingOutboxCount > 0)
                        SettingsItem(
                          icon: Icons.cloud_upload_outlined,
                          title: context.l10n.syncPendingChanges(
                            snapshot.pendingOutboxCount,
                          ),
                        ),
                      if (snapshot.status == SyncStatus.error &&
                          snapshot.lastError != null)
                        SettingsItem(
                          icon: Icons.error_outline,
                          title: snapshot.lastError!,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      if (snapshot.status == SyncStatus.disabled)
                        SettingsItem(
                          icon: Icons.info_outline,
                          title: context.l10n.syncUnavailableMessage,
                        )
                      else ...[
                        if (snapshot.status == SyncStatus.signedOut ||
                            snapshot.status == SyncStatus.error)
                          SettingsItem(
                            icon: Icons.login,
                            title: context.l10n.syncSignIn,
                            onTap: () => unawaited(
                              ref.read(syncStateProvider.notifier).signIn(),
                            ),
                          ),
                        if (snapshot.isActive)
                          SettingsItem(
                            icon: Icons.sync,
                            title: context.l10n.syncNow,
                            onTap: snapshot.status == SyncStatus.syncing
                                ? null
                                : () => unawaited(
                                    ref
                                        .read(syncStateProvider.notifier)
                                        .syncNow(),
                                  ),
                          ),
                        if (snapshot.isActive)
                          SettingsItem(
                            icon: Icons.logout,
                            title: context.l10n.syncSignOut,
                            onTap: () => unawaited(
                              ref.read(syncStateProvider.notifier).signOut(),
                            ),
                          ),
                      ],
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    child: Text(
                      context.l10n.syncSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _statusIcon(SyncStatus status) {
    switch (status) {
      case SyncStatus.disabled:
        return Icons.cloud_off_outlined;
      case SyncStatus.signedOut:
        return Icons.cloud_queue;
      case SyncStatus.idle:
        return Icons.cloud_done_outlined;
      case SyncStatus.syncing:
        return Icons.sync;
      case SyncStatus.error:
        return Icons.sync_problem;
    }
  }

  String _statusLabel(BuildContext context, SyncStatus status) {
    switch (status) {
      case SyncStatus.disabled:
        return context.l10n.syncStatusDisabled;
      case SyncStatus.signedOut:
        return context.l10n.syncStatusSignedOut;
      case SyncStatus.idle:
        return context.l10n.syncStatusIdle;
      case SyncStatus.syncing:
        return context.l10n.syncStatusSyncing;
      case SyncStatus.error:
        return context.l10n.syncStatusError;
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
