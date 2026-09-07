import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/qr_code.dart';

/// Draws a QR code for [value] using the in-app [QrEncoder] (no platform
/// channel, no extra dependency).
///
/// The widget sizes itself to [pixelSize] * (modules + 2 * quiet zone), so
/// it can be placed in any layout without an explicit [height]/[width].
/// When [value] is too long for QR byte mode (v40), the widget renders a
/// compact error tile instead of throwing.
class QrCodeWidget extends StatelessWidget {
  const QrCodeWidget({
    super.key,
    required this.value,
    this.level = QrErrorLevel.medium,
    this.pixelSize = 12.0,
    this.quietZoneModules = 4,
    this.foregroundColor = Colors.black,
    this.backgroundColor = Colors.white,
  });

  /// The text to encode (UTF-8).
  final String value;

  /// Error correction level. [QrErrorLevel.high] is recommended when the
  /// code may be partially obscured (e.g. low-resolution screenshots).
  final QrErrorLevel level;

  /// Logical pixels per module.
  final double pixelSize;

  /// ISO quiet zone width in modules on every side.
  final int quietZoneModules;

  final Color foregroundColor;
  final Color backgroundColor;

  static QrCode? _tryEncode(String value, {required QrErrorLevel level}) {
    try {
      return QrEncoder.encode(value, level: level);
    } on ArgumentError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = QrCodeWidget._tryEncode(value, level: level);
    if (code == null) {
      return Container(
        width: 96,
        height: 96,
        color: backgroundColor,
        alignment: Alignment.center,
        child: Icon(
          Icons.qr_code_2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    final side = pixelSize * (code.size + quietZoneModules * 2);
    return SizedBox(
      width: side,
      height: side,
      child: CustomPaint(
        painter: _QrCodePainter(
          code: code,
          quietZoneModules: quietZoneModules,
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
        ),
      ),
    );
  }
}

class _QrCodePainter extends CustomPainter {
  _QrCodePainter({
    required this.code,
    required this.quietZoneModules,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final QrCode code;
  final int quietZoneModules;
  final Color foregroundColor;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final n = code.size;
    final scale = size.width / (n + quietZoneModules * 2);

    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRect(
      Offset.zero & size,
      bgPaint,
    );

    final fgPaint = Paint()..color = foregroundColor;
    final offset = quietZoneModules * scale;
    for (var row = 0; row < n; row++) {
      final rowModules = code.modules[row];
      for (var col = 0; col < n; col++) {
        if (!rowModules[col]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            offset + col * scale,
            offset + row * scale,
            scale,
            scale,
          ),
          fgPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrCodePainter oldDelegate) =>
      oldDelegate.code != code ||
      oldDelegate.quietZoneModules != quietZoneModules ||
      oldDelegate.foregroundColor != foregroundColor ||
      oldDelegate.backgroundColor != backgroundColor;
}

/// Shows a QR code dialog for [url] with the link text and copy action.
///
/// Returns `true` if the link was copied, `false` otherwise.
Future<bool> showQrCodeDialog(
  BuildContext context, {
  required String url,
  String? title,
  QrErrorLevel level = QrErrorLevel.medium,
}) async {
  final copied = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title ?? 'QR Code'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: QrCodeWidget(
                    value: url,
                    level: level,
                    pixelSize: 8,
                    foregroundColor: colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                url,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Close'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('Copy link'),
          ),
        ],
      );
    },
  );
  if (copied == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied to clipboard')),
    );
  }
  return copied == true;
}
