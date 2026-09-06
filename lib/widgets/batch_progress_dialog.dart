import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

class _BatchProgress {
  final int current;
  final String? detail;
  const _BatchProgress({this.current = 0, this.detail});
}

/// A reusable progress dialog for batch operations like conversion and
/// re-enrich. Follows the same visual style as [_FetchingProgressDialog] in
/// artist_screen.dart.
///
/// Uses a static [ValueNotifier] so callers do not need the dialog's
/// [BuildContext] to push updates – unlike `findAncestorStateOfType` which
/// fails because the dialog lives in a separate navigator route.
///
/// Usage:
/// ```dart
/// var cancelled = false;
/// BatchProgressDialog.show(
///   context: context,
///   title: 'Converting...',
///   total: items.length,
///   icon: Icons.transform,
///   onCancel: () {
///     cancelled = true;
///     BatchProgressDialog.dismiss(context);
///   },
/// );
///
/// for (int i = 0; i < items.length; i++) {
///   if (cancelled) break;
///   BatchProgressDialog.update(current: i + 1, detail: items[i].name);
///   await doWork(items[i]);
/// }
///
/// BatchProgressDialog.dismiss(context);
/// ```
class BatchProgressDialog extends StatefulWidget {
  final String title;
  final int total;
  final IconData icon;
  final VoidCallback onCancel;
  final ValueNotifier<_BatchProgress> _progressNotifier;

  // ignore: prefer_const_constructors_in_immutables
  BatchProgressDialog._({
    required this.title,
    required this.total,
    required this.icon,
    required this.onCancel,
    required ValueNotifier<_BatchProgress> progressNotifier,
  }) : _progressNotifier = progressNotifier;

  static ValueNotifier<_BatchProgress>? _activeNotifier;
  static NavigatorState? _activeNavigator;

  static void show({
    required BuildContext context,
    required String title,
    required int total,
    required VoidCallback onCancel,
    IconData icon = Icons.transform,
  }) {
    // Each dialog owns its notifier and disposes it in `whenComplete` below,
    // so an overlapping `show()` must not dispose the previous one here
    // (ChangeNotifier.dispose() asserts on a second call).
    final notifier = ValueNotifier(const _BatchProgress());
    _activeNotifier = notifier;
    _activeNavigator = Navigator.of(context, rootNavigator: true);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        // The system back gesture must not silently close the dialog: the
        // caller's `cancelled` flag would stay false and the final
        // `dismiss()` would then pop the *page underneath*. Route back to
        // the same handler as the Cancel button instead.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onCancel();
        },
        child: BatchProgressDialog._(
          title: title,
          total: total,
          icon: icon,
          onCancel: onCancel,
          progressNotifier: notifier,
        ),
      ),
    ).whenComplete(() {
      if (identical(_activeNotifier, notifier)) {
        _activeNotifier = null;
        _activeNavigator = null;
      }
      // Safe: ChangeNotifier.removeListener tolerates a disposed notifier, so
      // the dialog state's dispose() cannot race with this.
      notifier.dispose();
    });
  }

  static void update({required int current, String? detail}) {
    _activeNotifier?.value = _BatchProgress(current: current, detail: detail);
  }

  /// Closes the progress dialog if (and only if) it is still on screen.
  ///
  /// Callers invoke this both from `onCancel` and after their loop finishes,
  /// so it must be idempotent: an unconditional `Navigator.pop()` used to pop
  /// the underlying page whenever the dialog was already gone.
  static void dismiss(BuildContext context) {
    final notifier = _activeNotifier;
    if (notifier == null) return;
    _activeNotifier = null;
    final navigator = _activeNavigator ?? Navigator.maybeOf(context, rootNavigator: true);
    _activeNavigator = null;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  State<BatchProgressDialog> createState() => _BatchProgressDialogState();
}

class _BatchProgressDialogState extends State<BatchProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget._progressNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget._progressNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final current = widget._progressNotifier.value.current;
    final detail = widget._progressNotifier.value.detail;
    final progress = widget.total > 0 ? current / widget.total : 0.0;

    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress > 0 ? progress : null,
                  strokeWidth: 4,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                ),
                Icon(widget.icon, color: colorScheme.primary, size: 24),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.title,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '$current / ${widget.total}',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              backgroundColor: colorScheme.surfaceContainerHighest,
              minHeight: 6,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: Text(context.l10n.dialogCancel),
        ),
      ],
    );
  }
}
