import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

/// Shared discard-unsaved-changes confirmation dialog used by priority /
/// selection settings pages.
Future<bool> showDiscardChangesDialog(
  BuildContext context, {
  String? content,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.dialogDiscardChanges),
      content: Text(content ?? context.l10n.dialogUnsavedChanges),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.dialogDiscard),
        ),
      ],
    ),
  );
  return result ?? false;
}
