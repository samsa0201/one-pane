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

/// Glass panel modelled on Apple's Liquid Glass (without the refraction shader, which needs the
/// Flutter GPU preview and is heavy on mid-range Android):
/// - backdrop blur + saturation boost (the glass picks up and intensifies what is behind it)
/// - an adaptive dark tint so text on it stays legible over a busy terminal
/// - a specular glint on the edges facing the light (top-left), a hairline dark contour outside and
///   a soft inner shadow along the bottom edge (the bevel's thickness)
/// Off ([glassEffects] false): the same shape, opaque, no backdrop work at all.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// Tint over the frosted backdrop: higher = more opaque / more legible.
  final double tint;

  /// Glint and fill strength (selected / raised elements use more).
  final double strength;
  const Glass({
    super.key,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.blur = 24,
    this.tint = 0.35,
    this.strength = 1,
  });

  /// Saturation matrix (1 = unchanged).
  static List<double> _saturate(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      i * r + s, i * g, i * b, 0, 0, //
      i * r, i * g + s, i * b, 0, 0,
      i * r, i * g, i * b + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  static final _filters = <double, ImageFilter>{};

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: glassEffects,
    builder: (context, on, _) {
      // Own Material: list tiles / ink inside paint on the glass, not on whatever is underneath.
      final body = Material(
        type: MaterialType.transparency,
        child: padding == null ? child : Padding(padding: padding!, child: child),
      );
      final panel = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: on ? Color.fromRGBO(14, 17, 24, tint) : const Color(0xFF1B1E26),
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.fromRGBO(255, 255, 255, 0.10 * strength),
                    Color.fromRGBO(14, 17, 24, tint),
                    Color.fromRGBO(14, 17, 24, tint + 0.08),
                  ],
                  stops: const [0, 0.45, 1],
                )
              : null,
          boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(borderRadius: radius, border: _Rim(radius, strength)),
          child: body,
        ),
      );
      if (!on) return panel;
      final filter = _filters[blur] ??= ImageFilter.compose(
        outer: ColorFilter.matrix(_saturate(1.8)),
        inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
      );
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(filter: filter, child: panel),
      );
    },
  );
}

/// The bevel: glint on the top-left walls, hairline dark contour, inner shadow at the bottom.
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
    final rr = radius.toRRect(rect);
    // inner shadow along the bottom (thickness)
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRRect(
      rr.shift(const Offset(0, -2)).inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();
    // hairline contour
    canvas.drawRRect(
      rr.deflate(0.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = const Color(0x66000000),
    );
    // specular glint: strongest at the top-left, a faint return at the bottom-right
    canvas.drawRRect(
      rr.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.fromRGBO(255, 255, 255, (0.55 * strength).clamp(0, 1)),
            Color.fromRGBO(255, 255, 255, 0.10 * strength),
            Color.fromRGBO(255, 255, 255, 0.04),
            Color.fromRGBO(255, 255, 255, 0.22 * strength),
          ],
          stops: const [0, 0.3, 0.7, 1],
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
