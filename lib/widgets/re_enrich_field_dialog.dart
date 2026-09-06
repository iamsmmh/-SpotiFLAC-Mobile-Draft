import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:spotiflac_android/services/batch_metadata_re_enrich.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

Future<ReEnrichFieldSelection?> showReEnrichFieldDialog(
  BuildContext context, {
  required int selectedCount,
}) {
  return showAppBottomSheet<ReEnrichFieldSelection>(
    context: context,
    useRootNavigator: true,
    title: AppLocalizations.of(context).trackReEnrich,
    subtitle: AppLocalizations.of(context).trackReEnrichOnlineSubtitle,
    maxHeightFactor: 0.9,
    builder: (ctx) => _ReEnrichFieldSheet(selectedCount: selectedCount),
  );
}

class _ReEnrichFieldSheet extends StatefulWidget {
  final int selectedCount;
  const _ReEnrichFieldSheet({required this.selectedCount});

  @override
  State<_ReEnrichFieldSheet> createState() => _ReEnrichFieldSheetState();
}

class _ReEnrichFieldSheetState extends State<_ReEnrichFieldSheet> {
  final Set<String> _selected = Set<String>.from(ReEnrichFields.all);
  ReEnrichBatchMode _mode = ReEnrichBatchMode.missingOnly;

  bool get _allSelected => _selected.length == ReEnrichFields.all.length;

  void _toggleAll(bool? value) {
    setState(() {
      if (value == true) {
        _selected.addAll(ReEnrichFields.all);
      } else {
        _selected.clear();
      }
    });
  }

  void _toggle(String field, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(field);
      } else {
        _selected.remove(field);
      }
    });
  }

  String _labelFor(String field, AppLocalizations l10n) {
    switch (field) {
      case ReEnrichFields.cover:
        return l10n.trackReEnrichFieldCover;
      case ReEnrichFields.lyrics:
        return l10n.trackReEnrichFieldLyrics;
      case ReEnrichFields.basicTags:
        return l10n.trackReEnrichFieldBasicTags;
      case ReEnrichFields.trackInfo:
        return l10n.trackReEnrichFieldTrackInfo;
      case ReEnrichFields.releaseInfo:
        return l10n.trackReEnrichFieldReleaseInfo;
      case ReEnrichFields.extra:
        return l10n.trackReEnrichFieldExtra;
      default:
        return field;
    }
  }

  IconData _iconFor(String field) {
    switch (field) {
      case ReEnrichFields.cover:
        return Icons.image_outlined;
      case ReEnrichFields.lyrics:
        return Icons.lyrics_outlined;
      case ReEnrichFields.basicTags:
        return Icons.album_outlined;
      case ReEnrichFields.trackInfo:
        return Icons.format_list_numbered;
      case ReEnrichFields.releaseInfo:
        return Icons.calendar_today_outlined;
      case ReEnrichFields.extra:
        return Icons.label_outline;
      default:
        return Icons.tag;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                l10n.downloadedAlbumSelectedCount(widget.selectedCount),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SettingsGroup(
              children: [
                ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: Text(l10n.trackReEnrichModeIsrc),
                  subtitle: Text(l10n.trackReEnrichModeIsrcSubtitle),
                  trailing: _mode == ReEnrichBatchMode.isrcOnly
                      ? Icon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () =>
                      setState(() => _mode = ReEnrichBatchMode.isrcOnly),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.playlist_add_check),
                  title: Text(l10n.trackReEnrichModeMissing),
                  subtitle: Text(l10n.trackReEnrichModeMissingSubtitle),
                  trailing: _mode == ReEnrichBatchMode.missingOnly
                      ? Icon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () =>
                      setState(() => _mode = ReEnrichBatchMode.missingOnly),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: Text(l10n.trackReEnrichModeReplace),
                  subtitle: Text(l10n.trackReEnrichModeReplaceSubtitle),
                  trailing: _mode == ReEnrichBatchMode.selectedFields
                      ? Icon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () =>
                      setState(() => _mode = ReEnrichBatchMode.selectedFields),
                ),
              ],
            ),
            if (_mode == ReEnrichBatchMode.selectedFields) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  l10n.trackReEnrichFieldsTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SettingsGroup(
                children: [
                  CheckboxListTile(
                    title: Text(
                      l10n.trackReEnrichSelectAll,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    value: _allSelected,
                    tristate: true,
                    onChanged: _toggleAll,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  for (final field in ReEnrichFields.all) ...[
                    const Divider(height: 1, indent: 56),
                    CheckboxListTile(
                      secondary: Icon(_iconFor(field), size: 20),
                      title: Text(_labelFor(field, l10n)),
                      value: _selected.contains(field),
                      onChanged: (value) => _toggle(field, value),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _mode == ReEnrichBatchMode.selectedFields &&
                          _selected.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          ReEnrichFieldSelection(
                            mode: _mode,
                            fields: _selected.toList(),
                          ),
                        ),
                  icon: const Icon(Icons.preview_outlined, size: 18),
                  label: Text(l10n.trackReEnrichReview),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
