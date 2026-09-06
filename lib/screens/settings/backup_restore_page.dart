import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/l10n/staged_strings.dart';
import 'package:spotiflac_android/services/backup_service.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/services/library_ledger_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';

class BackupRestorePage extends ConsumerStatefulWidget {
  const BackupRestorePage({super.key});

  @override
  ConsumerState<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends ConsumerState<BackupRestorePage> {
  static final _log = AppLogger('BackupRestorePage');

  bool _isExporting = false;
  bool _isImporting = false;
  bool _isLedgerBusy = false;
  bool _includeSecrets = false;

  bool get _isBusy => _isExporting || _isImporting || _isLedgerBusy;

  Future<void> _createBackup() async {
    if (_isBusy) return;
    setState(() => _isExporting = true);
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final settings = ref.read(settingsProvider).toJson();
      final history = await HistoryDatabase.instance.getAll();
      final collectionsNotifier = ref.read(libraryCollectionsProvider.notifier);
      final collections = await collectionsNotifier.exportCollections();
      final covers = await collectionsNotifier.exportPlaylistCovers();
      final extensions = await ref
          .read(extensionProvider.notifier)
          .exportBackup(includeSecrets: _includeSecrets);

      final envelope = BackupService.buildEnvelope(
        settings: settings,
        history: history,
        collections: collections,
        playlistCovers: covers,
        extensions: extensions,
      );

      final file = await BackupService.writeBackupFile(envelope);

      messenger.showSnackBar(SnackBar(content: Text(l10n.backupCreated)));

      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: l10n.backupTitle),
      );
    } catch (e, stack) {
      _log.e('Failed to create backup: $e', e, stack);
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupCreateFailed)));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportLedger() async {
    if (_isBusy) return;
    setState(() => _isLedgerBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final rows = await HistoryDatabase.instance.getAll();
      final entries = LibraryLedgerService.entriesFromHistoryRows(rows);
      final file = await LibraryLedgerService.writeLedgerFile(
        LibraryLedgerService.encodeLedger(entries),
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: StagedStrings.ledgerSectionTitle),
      );
      messenger.showSnackBar(
        SnackBar(content: Text(StagedStrings.ledgerExported)),
      );
    } catch (e, stack) {
      _log.e('Failed to export ledger: $e', e, stack);
      messenger.showSnackBar(
        SnackBar(content: Text(StagedStrings.ledgerExportFailed)),
      );
    } finally {
      if (mounted) setState(() => _isLedgerBusy = false);
    }
  }

  Future<void> _importLedger() async {
    if (_isBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    List<LedgerEntry>? imported;
    try {
      final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
      if (picked == null) return;
      imported = LibraryLedgerService.decodeLedger(
        utf8.decode(await picked.readAsBytes()),
      );
    } catch (e) {
      _log.e('Failed to read ledger file: $e');
      messenger.showSnackBar(
        SnackBar(content: Text(StagedStrings.ledgerInvalidFile)),
      );
      return;
    }

    if (imported == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(StagedStrings.ledgerInvalidFile)),
      );
      return;
    }

    final localRows = await HistoryDatabase.instance.getAll();
    final missing = LibraryLedgerService.missingEntries(
      imported: imported,
      local: LibraryLedgerService.entriesFromHistoryRows(localRows),
    );

    if (!mounted) return;
    if (missing.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(StagedStrings.ledgerAllPresent)),
      );
      return;
    }
    await _showLedgerMissingDialog(missing);
  }

  Future<void> _showLedgerMissingDialog(List<LedgerEntry> missing) async {
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${StagedStrings.ledgerMissingTitle} (${missing.length})',
        ),
        contentPadding: const EdgeInsets.only(top: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: missing.length,
            itemBuilder: (context, index) {
              final entry = missing[index];
              final url = entry.openableUrl;
              return ListTile(
                dense: true,
                title: Text(entry.displayLabel),
                subtitle: entry.album.isEmpty
                    ? null
                    : Text(entry.album, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: url ?? StagedStrings.ledgerSearchHint,
                  icon: Icon(
                    url == null ? Icons.copy_all_outlined : Icons.open_in_new,
                  ),
                  onPressed: () async {
                    if (url != null) {
                      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                      return;
                    }
                    await Clipboard.setData(ClipboardData(text: entry.displayLabel));
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    messenger.showSnackBar(
                      const SnackBar(content: Text(StagedStrings.ledgerCopiedList)),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final text = missing.map((e) => e.displayLabel).join('\n');
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              messenger.showSnackBar(
                const SnackBar(content: Text(StagedStrings.ledgerCopiedList)),
              );
            },
            child: const Text(StagedStrings.ledgerCopyList),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(StagedStrings.ledgerClose),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreBackup() async {
    if (_isBusy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    String? content;
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json', BackupService.fileExtension],
      );
      if (picked == null) return;
      content = utf8.decode(await picked.readAsBytes());
    } catch (e) {
      _log.e('Failed to read backup file: $e');
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupInvalidFile)));
      return;
    }

    final bundle = BackupService.parse(content);
    if (bundle == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupInvalidFile)));
      return;
    }

    if (!mounted) return;
    final confirmed = await _confirmRestore(bundle);
    if (confirmed != true || !mounted) return;

    setState(() => _isImporting = true);
    try {
      if (bundle.hasSettings) {
        await ref
            .read(settingsProvider.notifier)
            .restoreFromBackup(bundle.settings!);
      }
      await ref
          .read(downloadHistoryProvider.notifier)
          .restoreFromBackup(bundle.history);
      await ref
          .read(libraryCollectionsProvider.notifier)
          .restoreFromBackup(
            bundle.collections,
            coverImages: bundle.playlistCovers,
          );

      ExtensionRestoreResult? extResult;
      if (bundle.hasExtensions) {
        extResult = await ref
            .read(extensionProvider.notifier)
            .restoreFromBackup(bundle.extensions);
      }

      final message = StringBuffer(l10n.backupRestored)
        ..write('\n')
        ..write(l10n.backupRestoreRestartHint);
      if (extResult != null && extResult.failed > 0) {
        message
          ..write('\n')
          ..write(l10n.backupExtensionsRestoreFailed(extResult.failed));
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(message.toString()),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e, stack) {
      _log.e('Failed to restore backup: $e', e, stack);
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupRestoreFailed)));
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<bool?> _confirmRestore(BackupBundle bundle) {
    final l10n = context.l10n;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.backupRestoreConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.backupRestoreConfirmMessage),
              const SizedBox(height: 16),
              Text(
                l10n.backupContentsTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              if (bundle.hasSettings)
                _ContentRow(
                  icon: Icons.settings_outlined,
                  label: l10n.backupContentsSettings,
                ),
              _ContentRow(
                icon: Icons.history,
                label: l10n.backupContentsHistory(bundle.historyCount),
              ),
              _ContentRow(
                icon: Icons.favorite_outline,
                label: l10n.backupContentsLiked(bundle.likedCount),
              ),
              _ContentRow(
                icon: Icons.bookmark_outline,
                label: l10n.backupContentsWishlist(bundle.wishlistCount),
              ),
              _ContentRow(
                icon: Icons.queue_music_outlined,
                label: l10n.backupContentsPlaylists(bundle.playlistCount),
              ),
              if (bundle.favoriteArtistCount > 0)
                _ContentRow(
                  icon: Icons.person_outline,
                  label: l10n.backupContentsArtists(bundle.favoriteArtistCount),
                ),
              if (bundle.favoriteAlbumCount > 0)
                _ContentRow(
                  icon: Icons.album_outlined,
                  label: l10n.backupContentsAlbums(bundle.favoriteAlbumCount),
                ),
              if (bundle.extensionCount > 0)
                _ContentRow(
                  icon: Icons.extension_outlined,
                  label: l10n.backupContentsExtensions(bundle.extensionCount),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.dialogCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.backupRestoreConfirmButton),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.backupTitle),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.backupExportSectionTitle),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.vpn_key_outlined,
                  title: l10n.backupIncludeSecrets,
                  subtitle: l10n.backupIncludeSecretsDescription,
                  value: _includeSecrets,
                  onChanged: _isBusy
                      ? null
                      : (value) => setState(() => _includeSecrets = value),
                ),
                SettingsItem(
                  icon: Icons.ios_share,
                  title: l10n.backupExportButton,
                  subtitle: l10n.backupExportSectionDescription,
                  onTap: _isBusy ? null : _createBackup,
                  trailing: _isExporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  showDivider: false,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.backupImportSectionTitle),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.settings_backup_restore,
                  title: l10n.backupImportButton,
                  subtitle: l10n.backupImportSectionDescription,
                  onTap: _isBusy ? null : _restoreBackup,
                  trailing: _isImporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  showDivider: false,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: StagedStrings.ledgerSectionTitle,
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.inventory_2_outlined,
                  title: StagedStrings.ledgerExportButton,
                  subtitle: StagedStrings.ledgerExportDescription,
                  onTap: _isBusy ? null : _exportLedger,
                ),
                SettingsItem(
                  icon: Icons.fact_check_outlined,
                  title: StagedStrings.ledgerImportButton,
                  subtitle: StagedStrings.ledgerImportDescription,
                  onTap: _isBusy ? null : _importLedger,
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _ContentRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ContentRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
