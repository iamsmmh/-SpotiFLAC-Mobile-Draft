import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

/// Shows a delete-confirmation dialog, deletes the given [ids] one by one via
/// [deleteItem], then shows a "deleted N tracks" snackbar.
/// [onExitSelectionMode] runs right after the delete loop, matching the
/// screens' original ordering.
///
/// Returns the number of items [deleteItem] reported deleted, or null if the
/// user cancelled the dialog.
Future<int?> confirmAndDeleteTracks({
  required BuildContext context,
  required List<String> ids,
  required Future<bool> Function(String id) deleteItem,
  required VoidCallback onExitSelectionMode,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(context.l10n.downloadedAlbumDeleteSelected),
      content: Text(context.l10n.downloadedAlbumDeleteMessage(ids.length)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(context.l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(context.l10n.dialogDelete),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return null;

  var deletedCount = 0;
  for (final id in ids) {
    if (await deleteItem(id)) deletedCount++;
  }

  onExitSelectionMode();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.snackbarDeletedTracks(deletedCount))),
    );
  }

  return deletedCount;
}
