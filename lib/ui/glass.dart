import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

/// "Liquid glass" look: frosted panels over a soft colour ambient. Off ([glassEffects] false): the
/// same shapes with an opaque fill and no backdrop blur, for slow phones.
final glassEffects = ValueNotifier<bool>(true);
const _glassPref = 'glassEffects';

Future<void> loadGlassPref() async {
  try {
    glassEffects.value = (await SharedPreferences.getInstance()).getBool(_glassPref) ?? true;
  } catch (_) {}
}

void setGlassEffects(bool on) {
  glassEffects.value = on;
  SharedPreferences.getInstance().then((p) => p.setBool(_glassPref, on)).catchError((_) => true);
}

/// Frosted panel: backdrop blur, a thin white gradient fill and a light rim brighter at the top.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// 0..1: how much the panel lifts off what is behind (fill and rim strength).
  final double strength;
  const Glass({
    super.key,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.blur = 22,
    this.strength = 1,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: glassEffects,
    builder: (context, on, _) {
      final panel = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.13 * strength),
                    Colors.white.withValues(alpha: 0.04 * strength),
                  ],
                )
              : null,
          color: on ? null : const Color(0xFF1C1F26),
          boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 6))],
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(borderRadius: radius, border: _Rim(radius, strength)),
          child: padding == null ? child : Padding(padding: padding!, child: child),
        ),
      );
      if (!on) return panel;
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: panel,
        ),
      );
    },
  );
}

/// Specular rim: bright along the top-left edge, fading toward the bottom.
class _Rim extends BoxBorder {
  final BorderRadius radius;
  final double strength;
  const _Rim(this.radius, this.strength);

  @override
  BorderSide get top => BorderSide.none;
  @override
  BorderSide get bottom => BorderSide.none;
  @override
  bool get isUniform => true;
  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(1);
  @override
  ShapeBorder scale(double t) => this;

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) {
    final rrect = radius.toRRect(rect).deflate(0.5);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.45 * strength),
            Colors.white.withValues(alpha: 0.06 * strength),
            Colors.white.withValues(alpha: 0.14 * strength),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }
}

/// Soft colour fields behind everything (what the glass refracts). Static: painted once.
class Ambient extends StatelessWidget {
  const Ambient({super.key});

  @override
  Widget build(BuildContext context) => const RepaintBoundary(child: CustomPaint(painter: _AmbientPainter()));
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF07080C));
    void blob(Offset c, double r, Color color) => canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final w = size.width, h = size.height;
    blob(Offset(w * 0.1, h * 0.08), w * 0.9, const Color(0x664FC3F7));
    blob(Offset(w * 0.95, h * 0.55), w * 0.8, const Color(0x557C4DFF));
    blob(Offset(w * 0.2, h * 0.95), w * 0.85, const Color(0x4426C6DA));
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => false;
}

/// Bottom sheet on glass (transparent sheet, the content wrapped in a top-rounded [Glass]).
Future<T?> showGlassSheet<T>({required BuildContext context, required WidgetBuilder builder}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true, // a long sheet stops below the status bar
      backgroundColor: Colors.transparent,
      elevation: 0,
      showDragHandle: false,
      builder: (ctx) => Glass(
        radius: const BorderRadius.vertical(top: Radius.circular(28)),
        blur: 28,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2)),
            ),
            Flexible(child: builder(ctx)),
          ],
        ),
      ),
    );

/// Terminal colours (xterm's defaults) on a slightly see-through background: the ambient glows
/// faintly behind the text without hurting contrast.
const terminalTheme = TerminalTheme(
  cursor: Color(0xCC4FC3F7),
  selection: Color(0x664FC3F7),
  foreground: Color(0xFFD4D7DD),
  background: Color(0xD90A0C11),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF0DBC79),
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFF14C4C),
  brightGreen: Color(0xFF23D18B),
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);
