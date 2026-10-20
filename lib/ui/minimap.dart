import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../tmux/layout.dart';

const accent = Color(0xFF4FC3F7);

/// Pane rectangles scaled (aspect kept, or [stretch]ed to fill) into [box], keyed by pane id.
Map<int, Rect> scaleRects(List<PaneRect> panes, Size box, {bool stretch = false}) {
  if (panes.isEmpty) return {};
  final w = panes.map((p) => p.x + p.w).reduce(max).toDouble();
  final h = panes.map((p) => p.y + p.h).reduce(max).toDouble();
  var sx = box.width / w, sy = box.height / h;
  if (!stretch) sx = sy = min(sx, sy);
  return {for (final p in panes) p.id: Rect.fromLTWH(p.x * sx, p.y * sy, p.w * sx, p.h * sy)};
}

/// Pane id under [pos] in a [box]-sized minimap, or null.
int? paneAt(List<PaneRect> panes, Size box, Offset pos) {
  for (final e in scaleRects(panes, box, stretch: true).entries) {
    if (e.value.inflate(1).contains(pos)) return e.key;
  }
  return null;
}

class MiniMap extends StatelessWidget {
  final List<PaneRect> panes;
  final int? currentId;
  final Size size;
  final ValueChanged<int>? onTapPane;
  final VoidCallback? onLongPress;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final GestureDragCancelCallback? onPanCancel;

  const MiniMap({
    super.key,
    required this.panes,
    this.currentId,
    this.size = const Size(64, 40),
    this.onTapPane,
    this.onLongPress,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
  });

  @override
  Widget build(BuildContext context) {
    final detector = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onTapPane == null
          ? null
          : (d) {
              final id = paneAt(panes, size, d.localPosition);
              if (id != null) onTapPane!(id);
            },
      onLongPress: onLongPress,
      child: CustomPaint(size: size, painter: MiniMapPainter(panes, currentId)),
    );
    if (onPanUpdate == null) return detector;
    // A pan accepts after 2× touch slop, a parent's horizontal drag after 1×: halve ours so both accept
    // at the same distance, and ours wins (the pointer reaches the deepest recognizer first).
    final slop = (MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop) / 2;
    return RawGestureDetector(gestures: {
      PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
        () => PanGestureRecognizer(debugOwner: this),
        (r) => r
          ..gestureSettings = DeviceGestureSettings(touchSlop: slop)
          ..dragStartBehavior = DragStartBehavior.down // the slop's movement counts too
          ..onStart = onPanStart
          ..onUpdate = onPanUpdate
          ..onEnd = onPanEnd
          ..onCancel = onPanCancel,
      ),
    }, child: detector);
  }
}

class MiniMapPainter extends CustomPainter {
  final List<PaneRect> panes;
  final int? currentId;
  MiniMapPainter(this.panes, this.currentId);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = accent;
    final other = Paint()..color = Colors.white.withValues(alpha: 0.08);
    final stroke = Paint()
      ..color = Colors.white38
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // Small gaps and rounded corners read better than shared 1px borders.
    final small = size.shortestSide < 80;
    final radius = Radius.circular(small ? 2 : 6);
    // Stretched: the map keeps its shape when the window's aspect changes (keyboard up, zoom).
    for (final e in scaleRects(panes, size, stretch: true).entries) {
      final r = RRect.fromRectAndRadius(e.value.deflate(small ? 1 : 3), radius);
      canvas.drawRRect(r, e.key == currentId ? fill : other);
      if (e.key != currentId) canvas.drawRRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(MiniMapPainter old) => old.panes != panes || old.currentId != currentId;
}
