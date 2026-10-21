import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';

export 'theme.dart';

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

/// Floating panel (sheets, joystick, pills over the terminal). With [glassEffects]: a frosted
/// surface (backdrop blur + saturation, so it takes on the colours under it) with a hairline rim
/// lit along the top edge. Off: the same shape, opaque, no backdrop work at all.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// Opacity of the surface over the frosted backdrop: higher = more legible.
  final double tint;

  /// Rim brightness (selected elements use more).
  final double strength;
  const Glass({
    super.key,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.blur = 24,
    this.tint = 0.72,
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
          color: on ? Tone.surface.withValues(alpha: tint) : Tone.surface,
          border: Border.all(color: Tone.line, width: 0.5),
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(borderRadius: radius, border: _Rim(radius, strength)),
          child: body,
        ),
      );
      if (!on) return panel;
      final filter = _filters[blur] ??= ImageFilter.compose(
        outer: ColorFilter.matrix(_saturate(1.6)),
        inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
      );
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(filter: filter, child: panel),
      );
    },
  );
}

/// Light catching the top edge, fading out down the sides.
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
    canvas.drawRRect(
      radius.toRRect(rect).deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.fromRGBO(255, 255, 255, (0.16 * strength).clamp(0, 1)), const Color(0x00FFFFFF)],
          stops: const [0, 0.5],
        ).createShader(rect),
    );
  }
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
        radius: const BorderRadius.vertical(top: Radius.circular(24)),
        blur: 28,
        tint: 0.88,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 32,
              height: 4,
              decoration: BoxDecoration(color: Tone.faint, borderRadius: BorderRadius.circular(2)),
            ),
            Flexible(child: builder(ctx)),
          ],
        ),
      ),
    );
