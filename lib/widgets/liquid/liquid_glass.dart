library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';

/// Liquid Glass design system — Apple-style layered glass implemented natively
/// in Flutter (no plugins, no shaders, no platform code).
///
/// A glass surface is five cheap layers stacked with `ClipRRect`:
///   1. BackdropFilter blur (the "frost")
///   2. Translucent tint gradient (the "body")
///   3. Edge highlight: 1px gradient stroke + top specular line (the "rim")
///   4. Pointer-responsive radial glow (the "liquid" part — light follows touch)
///   5. Slow diagonal sheen sweep (the "surface" part)
///
/// Every layer degrades independently: no blur support → stronger tinted body;
/// reduced motion → sheen and pointer glow disabled; low-end devices → no
/// backdrop filter at all. Widgets never crash on a device without blur.

/// Immutable configuration for one glass surface.
@immutable
class LiquidGlassStyle {
  final double blurSigma;
  final double tintAlpha;
  final double highlightAlpha;
  final double borderAlpha;
  final double shadowAlpha;
  final bool sheen;
  final bool pointerGlow;
  final Color? accentOverride;

  const LiquidGlassStyle({
    this.blurSigma = 18,
    this.tintAlpha = 0.16,
    this.highlightAlpha = 0.28,
    this.borderAlpha = 0.14,
    this.shadowAlpha = 0.30,
    this.sheen = true,
    this.pointerGlow = true,
    this.accentOverride,
  });

  LiquidGlassStyle copyWith({
    double? blurSigma,
    double? tintAlpha,
    double? highlightAlpha,
    double? borderAlpha,
    double? shadowAlpha,
    bool? sheen,
    bool? pointerGlow,
    Color? accentOverride,
  }) => LiquidGlassStyle(
    blurSigma: blurSigma ?? this.blurSigma,
    tintAlpha: tintAlpha ?? this.tintAlpha,
    highlightAlpha: highlightAlpha ?? this.highlightAlpha,
    borderAlpha: borderAlpha ?? this.borderAlpha,
    shadowAlpha: shadowAlpha ?? this.shadowAlpha,
    sheen: sheen ?? this.sheen,
    pointerGlow: pointerGlow ?? this.pointerGlow,
    accentOverride: accentOverride ?? this.accentOverride,
  );
}

/// Reads the current glass capability profile for one screen.
class LiquidGlassCapabilities {
  final bool blur;
  final bool sheen;
  final bool pointerGlow;
  final bool useHapticStyle;

  const LiquidGlassCapabilities({
    required this.blur,
    required this.sheen,
    required this.pointerGlow,
    required this.useHapticStyle,
  });

  /// Resolved from the runtime profile, user settings, and OS accessibility.
  static LiquidGlassCapabilities of(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final disabledAnimations = mediaQuery.disableAnimations;
    final highContrast = mediaQuery.highContrast;

    final profile = context
        .dependOnInheritedWidgetOfExactType<LiquidGlassScopeData>()
        ?.capabilities;
    if (profile != null) return profile;

    // Outside a LiquidGlassScope (tests, isolated previews) default to a
    // non-blurring glass so nothing requires a platform channel.
    return LiquidGlassCapabilities(
      blur: false,
      sheen: !disabledAnimations && !highContrast,
      pointerGlow: !disabledAnimations && !highContrast,
      useHapticStyle: highContrast,
    );
  }
}

/// Injects capabilities from the app scope so every descendant shares one
/// profile without re-reading the provider per surface.
class LiquidGlassScope extends StatelessWidget {
  final LiquidGlassCapabilities capabilities;
  final Widget child;

  const LiquidGlassScope({
    super.key,
    required this.capabilities,
    required this.child,
  });

  @override
  Widget build(BuildContext context) =>
      LiquidGlassScopeData(capabilities: capabilities, child: child);
}

class LiquidGlassScopeData extends InheritedWidget {
  final LiquidGlassCapabilities capabilities;

  const LiquidGlassScopeData({
    super.key,
    required this.capabilities,
    required super.child,
  });

  @override
  bool updateShouldNotify(LiquidGlassScopeData oldWidget) =>
      capabilities.blur != oldWidget.capabilities.blur ||
      capabilities.sheen != oldWidget.capabilities.sheen ||
      capabilities.pointerGlow != oldWidget.capabilities.pointerGlow;
}

/// Builds capabilities from Riverpod at the app shell level.
class LiquidGlassCapabilitiesHost extends ConsumerWidget {
  final Widget child;

  const LiquidGlassCapabilitiesHost({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blurAvailable = ref.watch(backdropBlurEnabledProvider);
    final settings = ref.watch(engineSettingsProvider);
    final mediaQuery = MediaQuery.of(context);
    final disabledAnimations = mediaQuery.disableAnimations;
    return LiquidGlassScope(
      capabilities: LiquidGlassCapabilities(
        blur: blurAvailable,
        sheen: settings.glassSheenEnabled && !disabledAnimations,
        pointerGlow: settings.glassPointerGlow && !disabledAnimations,
        useHapticStyle: mediaQuery.highContrast,
      ),
      child: child,
    );
  }
}

/// The layered glass surface.
class GlassSurface extends ConsumerWidget {
  final Widget child;
  final BorderRadius? borderRadius;
  final LiquidGlassStyle style;
  final EdgeInsets? padding;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.style = const LiquidGlassStyle(),
    this.padding,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final caps = LiquidGlassCapabilities.of(context);
    final radius =
        borderRadius ?? BorderRadius.circular(context.tokens.radiusCard);

    final tintColor = style.accentOverride ?? scheme.surfaceContainerHigh;
    final tint = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: style.tintAlpha * 0.5),
            tintColor.withValues(alpha: style.tintAlpha),
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: style.tintAlpha * 0.35),
            tintColor.withValues(alpha: style.tintAlpha),
          );

    final layers = <Widget>[
      if (caps.blur)
        Positioned.fill(
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: style.blurSigma,
                sigmaY: style.blurSigma,
              ),
              blendMode: BlendMode.src,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        ),
      Positioned.fill(child: _GlassTint(radius: radius, color: tint)),
      if (style.pointerGlow && caps.pointerGlow)
        Positioned.fill(child: _GlassPointerGlow(radius: radius)),
      Positioned.fill(
        child: CustomPaint(
          painter: _GlassEdgePainter(
            radius: radius,
            style: style,
            isDark: isDark,
          ),
        ),
      ),
      if (style.sheen && caps.sheen)
        Positioned.fill(child: _GlassSheen(radius: radius)),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: style.shadowAlpha),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          ...layers,
          Padding(padding: padding ?? const EdgeInsets.all(12), child: child),
        ],
      ),
    );
  }
}

class _GlassTint extends StatelessWidget {
  final BorderRadius radius;
  final Color color;

  const _GlassTint({required this.radius, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: RadialGradient(
          center: const Alignment(-0.6, -0.8),
          radius: 1.6,
          colors: [
            Color.alphaBlend(Colors.white.withValues(alpha: 0.06), color),
            color,
          ],
        ),
      ),
    );
  }
}

/// Light that follows the pointer/touch across the surface.
class _GlassPointerGlow extends StatefulWidget {
  final BorderRadius radius;

  const _GlassPointerGlow({required this.radius});

  @override
  State<_GlassPointerGlow> createState() => _GlassPointerGlowState();
}

class _GlassPointerGlowState extends State<_GlassPointerGlow> {
  final ValueNotifier<Offset?> _position = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (event) => _position.value = event.localPosition,
      onExit: (_) => _position.value = null,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) => _position.value = details.localPosition,
        onPanUpdate: (details) => _position.value = details.localPosition,
        onPanEnd: (_) => _position.value = null,
        child: ValueListenableBuilder<Offset?>(
          valueListenable: _position,
          builder: (context, position, _) {
            if (position == null) return const SizedBox.shrink();
            return IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: widget.radius,
                  gradient: RadialGradient(
                    center: Alignment(
                      (position.dx / math.max(1, context.size?.width ?? 1)) * 2 - 1,
                      (position.dy / math.max(1, context.size?.height ?? 1)) * 2 - 1,
                    ),
                    radius: 0.9,
                    colors: [
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Slow diagonal light sweep.
class _GlassSheen extends StatefulWidget {
  final BorderRadius radius;

  const _GlassSheen({required this.radius});

  @override
  State<_GlassSheen> createState() => _GlassSheenState();
}

class _GlassSheenState extends State<_GlassSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: widget.radius,
              gradient: LinearGradient(
                begin: Alignment(-1 - 2 * (1 - t), -1),
                end: Alignment(-1 + 0.6 - 2 * (1 - t), 1),
                colors: [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.05),
                  Colors.white.withValues(alpha: 0.0),
                ],
                stops: const [0.4, 0.5, 0.6],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 1px "rim" of the glass: brighter on top, fading down, plus a faint outer
/// stroke for separation against busy artwork.
class _GlassEdgePainter extends CustomPainter {
  final BorderRadius radius;
  final LiquidGlassStyle style;
  final bool isDark;

  const _GlassEdgePainter({
    required this.radius,
    required this.style,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: style.borderAlpha + (isDark ? 0.06 : 0)),
          Colors.white.withValues(alpha: style.borderAlpha * 0.35),
        ],
      ).createShader(rect);
    canvas.drawRRect(radius.toRRect(rect.deflate(0.5)), borderPaint);

    // Top specular line — the bright edge above the border that sells "glass".
    final specular = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white.withValues(alpha: style.highlightAlpha * 0.5),
          Colors.white.withValues(alpha: style.highlightAlpha),
          Colors.white.withValues(alpha: style.highlightAlpha * 0.5),
        ],
      ).createShader(rect);
    final path = Path()
      ..moveTo(rect.left + 14, rect.top + 1)
      ..lineTo(rect.right - 14, rect.top + 1);
    canvas.drawPath(path, specular);
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) =>
      oldDelegate.style != style && oldDelegate.isDark != isDark;
}

/// Full-screen blurred backdrop with a soft "aurora" of ambient color.
/// Used behind the full-screen glass player.
class GlassScrim extends StatelessWidget {
  final Widget? child;
  final ImageProvider? backgroundImage;
  final Color? tintColor;
  final double blurSigma;
  final bool enableAurora;

  const GlassScrim({
    super.key,
    this.child,
    this.backgroundImage,
    this.tintColor,
    this.blurSigma = 24,
    this.enableAurora = true,
  });

  @override
  Widget build(BuildContext context) {
    final caps = LiquidGlassCapabilities.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final background = backgroundImage == null
        ? ColoredBox(color: scheme.surface)
        : ClipRect(
            child: Image(
              image: backgroundImage!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(color: scheme.surface),
            ),
          );

    final tint = tintColor ?? (isDark ? Colors.black : scheme.surface);

    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        if (caps.blur)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            blendMode: BlendMode.src,
            child: ColoredBox(
              color: tint.withValues(alpha: isDark ? 0.62 : 0.72),
            ),
          )
        else
          ColoredBox(color: tint.withValues(alpha: 0.92)),
        if (enableAurora) LiquidAurora(colorScheme: scheme, isDark: isDark),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.25),
              ],
            ),
          ),
        ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}

/// Ambient drifting light blobs rendered with cheap radial gradients (no
/// MaskFilter blur, no per-frame image ops).
class LiquidAurora extends StatefulWidget {
  final ColorScheme colorScheme;
  final bool isDark;

  const LiquidAurora({
    super.key,
    required this.colorScheme,
    required this.isDark,
  });

  @override
  State<LiquidAurora> createState() => _LiquidAuroraState();
}

class _LiquidAuroraState extends State<LiquidAurora>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  @override
  void initState() {
    super.initState();
    _controller
      ..repeat()
      ..addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
      _controller.value = 0.35;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _controller.value;
    final primary = widget.colorScheme.primary;
    final secondary = widget.colorScheme.secondary;
    final tertiary = widget.colorScheme.tertiary;

    return IgnorePointer(
      child: CustomPaint(
        painter: _AuroraPainter(
          t: t,
          primary: primary,
          secondary: secondary,
          tertiary: tertiary,
          isDark: widget.isDark,
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final bool isDark;

  const _AuroraPainter({
    required this.t,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    void blob(Offset center, double radius, Color color, double alphaLook) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alphaLook),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    final driftX = math.sin(t * math.pi * 2) * size.width * 0.18;
    final driftY = math.cos(t * math.pi * 2) * size.height * 0.12;
    final alpha = isDark ? 0.16 : 0.12;

    blob(
      Offset(size.width * 0.22 + driftX, size.height * 0.30 + driftY),
      size.width * 0.5,
      primary,
      alpha,
    );
    blob(
      Offset(size.width * 0.80 - driftX, size.height * 0.62 - driftY),
      size.width * 0.45,
      secondary,
      alpha * 0.8,
    );
    blob(
      Offset(size.width * 0.55 + driftX * 0.4, size.height * 0.9),
      size.width * 0.4,
      tertiary,
      alpha * 0.6,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary ||
      oldDelegate.tertiary != tertiary;
}

/// ---------------------------------------------------------------------------
/// Glass components
/// ---------------------------------------------------------------------------

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final surface = GlassSurface(
      borderRadius: borderRadius,
      padding: padding,
      child: child,
    );
    if (onTap == null) return surface;
    return GestureDetector(
      onTap: onTap,
      child: surface,
    );
  }
}

class GlassButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool prominent;

  const GlassButton({
    super.key,
    required this.child,
    this.onPressed,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      borderRadius: BorderRadius.circular(context.tokens.radiusControl),
      style: LiquidGlassStyle(
        blurSigma: 12,
        tintAlpha: 0.22,
        accentOverride: prominent ? scheme.primaryContainer : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: scheme.onPrimaryContainer,
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: child,
      ),
    );
  }
}

/// Icon-only glass control. `tooltip` is mandatory (accessibility contract).
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool prominent;

  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 48,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(size / 2 - 2);
    return GlassSurface(
      borderRadius: radius,
      style: LiquidGlassStyle(
        blurSigma: 10,
        tintAlpha: 0.2,
        sheen: false,
        pointerGlow: true,
        accentOverride: prominent ? scheme.primary : null,
      ),
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: size,
        width: size,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon),
          padding: EdgeInsets.zero,
          iconSize: size * 0.46,
          color: prominent ? scheme.onPrimaryContainer : scheme.onSurface,
          disabledColor: scheme.onSurface.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

class GlassChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const GlassChip({
    super.key,
    this.icon,
    required this.label,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = selected ? scheme.primary : null;
    return GlassSurface(
      borderRadius: BorderRadius.circular(99),
      style: LiquidGlassStyle(
        blurSigma: 8,
        tintAlpha: selected ? 0.32 : 0.14,
        sheen: false,
        pointerGlow: false,
        accentOverride: accent,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 16,
                color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GlassProgressBar extends StatelessWidget {
  final double value;
  final double? height;
  final bool animate;

  const GlassProgressBar({
    super.key,
    required this.value,
    this.height = 4,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      builder: (context, v, _) => ClipRRect(
        borderRadius: BorderRadius.circular(height!),
        child: LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: Colors.white.withValues(alpha: 0.18),
          valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
        ),
      ),
    );
  }
}

class GlassSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool enabled;

  const GlassSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.18),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      child: Slider(
        value: value.clamp(0.0, 1.0),
        onChanged: enabled ? (v) => onChanged?.call(v) : null,
        onChangeEnd: enabled ? (v) => onChangeEnd?.call(v) : null,
      ),
    );
  }
}

class GlassToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  const GlassToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Switch(
      value: value,
      onChanged: enabled ? (v) => onChanged?.call(v) : null,
      activeThumbColor: scheme.onPrimaryContainer,
      activeTrackColor: scheme.primary,
      inactiveThumbColor: scheme.onSurfaceVariant,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
    );
  }
}

/// Modal bottom sheet rendered as one glass card.
Future<T?> showLiquidBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  String? title,
  Widget? subtitle,
  bool isScrollControlled = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    builder: (sheetContext) {
      return GlassSurface(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.tokens.radiusSheet),
        ),
        style: LiquidGlassStyle(
          blurSigma: 26,
          tintAlpha: 0.34,
          borderAlpha: 0.22,
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              if (title != null) ...[
                const SizedBox(height: 14),
                Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle(
                  style: Theme.of(sheetContext).textTheme.bodyMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  child: subtitle,
                ),
              ],
              const SizedBox(height: 10),
              Flexible(child: builder(sheetContext)),
              const SizedBox(height: 6),
            ],
          ),
        ),
      );
    },
  );
}
