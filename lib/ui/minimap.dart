import 'dart:math';

import 'package:flutter/material.dart';

import '../tmux/layout.dart';

const accent = Color(0xFF4FC3F7);

/// Pane rectangles scaled (aspect kept) into [box], keyed by pane id.
Map<int, Rect> scaleRects(List<PaneRect> panes, Size box) {
  if (panes.isEmpty) return {};
  final w = panes.map((p) => p.x + p.w).reduce(max).toDouble();
  final h = panes.map((p) => p.y + p.h).reduce(max).toDouble();
  final s = min(box.width / w, box.height / h);
  return {for (final p in panes) p.id: Rect.fromLTWH(p.x * s, p.y * s, p.w * s, p.h * s)};
}

/// Pane id under [pos] in a [box]-sized minimap, or null.
int? paneAt(List<PaneRect> panes, Size box, Offset pos) {
  for (final e in scaleRects(panes, box).entries) {
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

  const MiniMap({
    super.key,
    required this.panes,
    this.currentId,
    this.size = const Size(64, 40),
    this.onTapPane,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
  }
}

class MiniMapPainter extends CustomPainter {
  final List<PaneRect> panes;
  final int? currentId;
  MiniMapPainter(this.panes, this.currentId);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = accent;
    final stroke = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final e in scaleRects(panes, size).entries) {
      final r = e.value.deflate(0.5);
      if (e.key == currentId) canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(MiniMapPainter old) => old.panes != panes || old.currentId != currentId;
}
