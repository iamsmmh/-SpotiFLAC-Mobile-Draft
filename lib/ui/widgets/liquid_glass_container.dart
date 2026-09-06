import 'dart:ui' as ui show ImageFilter;

import 'package:flutter/material.dart';

/// SpotiFLAC Mobile — Liquid Glass design system.
///
/// [LiquidGlassContainer] is the canonical reusable glass surface: a frosted
/// [BackdropFilter] (blur sigma 18) stacked under a semi-transparent tint, a
/// dynamic gradient border (white @ ~18% opacity), a soft drop shadow and
/// rounded corners.
///
/// It is intentionally dependency-free (Riverpod/theme-token free) so it can be
/// used from sheets, overlays, scaffolds and tests alike. The richer,
/// capability-aware [GlassSurface] used by the existing Liquid UI remains
/// available; this widget is the lightweight, spec-aligned building block the
/// SpotiFLAC Mobile screens are constructed from.
class LiquidGlassContainer extends StatelessWidget {
  /// The content floating on the glass.
  final Widget child;

  /// Corner radius. Defaults to 24 for cards; sheets use 28–32.
  final double borderRadius;

  /// Backdrop blur strength. The Liquid Glass spec uses 18.
  final double blurSigma;

  /// Padding applied inside the glass.
  final EdgeInsetsGeometry padding;

  /// Tint colour blended over the frosted backdrop. Defaults to a translucent
  /// white in dark mode / translucent dark in light mode.
  final Color? tintColor;

  /// Opacity of the tint body (0–1).
  final double tintOpacity;

  /// Opacity of the gradient border. The spec calls for
  /// `Colors.white.withOpacity(0.18)`.
  final double borderOpacity;

  /// Width of the gradient border stroke.
  final double borderWidth;

  /// Whether to paint the soft ambient shadow under the surface.
  final bool enableShadow;

  /// Optional accent used for the border highlight and glow. When null the
  /// current [ColorScheme.primary] is used at reduced strength.
  final Color? accentColor;

  /// Disable the blur layer (low-end devices / reduced motion). The tint and
  /// border remain so the surface is still visually distinct.
  final bool enableBlur;

  /// Optional background gradient drawn *behind* the blur but *inside* the
  /// clip, giving cards a subtle aurora body.
  final Gradient? bodyGradient;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.blurSigma = 18,
    this.padding = const EdgeInsets.all(16),
    this.tintColor,
    this.tintOpacity = 0.10,
    this.borderOpacity = 0.18,
    this.borderWidth = 1.2,
    this.enableShadow = true,
    this.accentColor,
    this.enableBlur = true,
    this.bodyGradient,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(borderRadius);

    final tint = tintColor ??
        (isDark
            ? Colors.white.withValues(alpha: tintOpacity)
            : scheme.surfaceContainerHighest.withValues(
                alpha: tintOpacity + 0.18,
              ));

    final accent = accentColor ?? scheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: enableShadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.12),
                  blurRadius: 30,
                  spreadRadius: -6,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: accent.withValues(alpha: 0.08),
                  blurRadius: 40,
                  spreadRadius: -10,
                  offset: const Offset(0, 0),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // 1. Frost — the layer that gives glass its translucency.
            if (enableBlur)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            // 2. Body — translucent tint + optional aurora gradient.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: bodyGradient ??
                      LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          tint,
                          Color.alphaBlend(
                            accent.withValues(alpha: 0.05),
                            tint,
                          ),
                        ],
                      ),
                ),
              ),
            ),
            // 3. Specular sheen — light falling across the top edge.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: isDark ? 0.10 : 0.22),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35],
                    ),
                  ),
                ),
              ),
            ),
            // 4. Content.
            Padding(padding: padding, child: child),
            // 5. Dynamic gradient border — white @ 18% along the rim.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LiquidGlassBorderPainter(
                    radius: radius,
                    borderOpacity: borderOpacity,
                    borderWidth: borderWidth,
                    accent: accent,
                    isDark: isDark,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the 1px gradient rim: a bright white segment along the top/left
/// (specular edge) fading to a faint accent-tinted line along the bottom/right.
class _LiquidGlassBorderPainter extends CustomPainter {
  final BorderRadius radius;
  final double borderOpacity;
  final double borderWidth;
  final Color accent;
  final bool isDark;

  _LiquidGlassBorderPainter({
    required this.radius,
    required this.borderOpacity,
    required this.borderWidth,
    required this.accent,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect).deflate(borderWidth / 2);

    final shader = SweepGradient(
      center: const Alignment(-0.4, -0.6),
      startAngle: 0,
      endAngle: 6.2832,
      colors: [
        // Top-left rim: the bright specular edge (white @ 18%).
        Colors.white.withValues(alpha: borderOpacity),
        Colors.white.withValues(alpha: borderOpacity * 0.55),
        // Bottom-right rim: faint accent-tinted shadow edge.
        accent.withValues(alpha: isDark ? 0.22 : 0.10),
        Colors.white.withValues(alpha: borderOpacity * 0.35),
        Colors.white.withValues(alpha: borderOpacity),
      ],
      stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
    ).createShader(rect);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..shader = shader;

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_LiquidGlassBorderPainter old) =>
      old.borderOpacity != borderOpacity ||
      old.borderWidth != borderWidth ||
      old.accent != accent ||
      old.isDark != isDark ||
      old.radius != radius;
}

/// A full-bleed, animated aurora background used behind glass scaffolds.
///
/// Two slow-drifting radial glows over the theme surface give the frosted
/// layers something colourful to refract.
class LiquidGlassBackground extends StatefulWidget {
  /// Content drawn above the aurora layers. When null (e.g. when the aurora is
  /// used as a standalone background sibling in a Stack) only the glows render.
  final Widget? child;

  const LiquidGlassBackground({super.key, this.child});

  @override
  State<LiquidGlassBackground> createState() => _LiquidGlassBackgroundState();
}

class _LiquidGlassBackgroundState extends State<LiquidGlassBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disable =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    if (disable) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: isDark ? const Color(0xFF07070B) : scheme.surface,
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              return Stack(
                children: [
                  Positioned(
                    left: -80 + 120 * t,
                    top: -40 - 60 * t,
                    child: _Glow(
                      color: scheme.primary.withValues(
                        alpha: isDark ? 0.28 : 0.16,
                      ),
                      size: 340,
                    ),
                  ),
                  Positioned(
                    right: -60 - 100 * t,
                    bottom: -80 + 80 * t,
                    child: _Glow(
                      color: scheme.tertiary.withValues(
                        alpha: isDark ? 0.24 : 0.14,
                      ),
                      size: 380,
                    ),
                  ),
                  Positioned(
                    left: 60 + 80 * (1 - t),
                    bottom: 120 - 40 * t,
                    child: _Glow(
                      color: scheme.secondary.withValues(
                        alpha: isDark ? 0.18 : 0.10,
                      ),
                      size: 260,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  final double size;

  const _Glow({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}
