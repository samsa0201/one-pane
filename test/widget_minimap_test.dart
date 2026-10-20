import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/layout.dart';
import 'package:tmux_pocket/ui/minimap.dart';

// 160x48 window: %0 left half, %1 top-right, %2 bottom-right.
const panes = [
  PaneRect(0, 0, 0, 80, 48),
  PaneRect(1, 81, 0, 79, 24),
  PaneRect(2, 81, 25, 79, 23),
];

void main() {
  test('scaleRects keeps relative positions inside the box', () {
    final r = scaleRects(panes, const Size(64, 40));
    expect(r[0]!.left, 0);
    expect(r[1]!.left, greaterThan(r[0]!.right - 1));
    expect(r[2]!.top, greaterThan(r[1]!.top));
    for (final rect in r.values) {
      expect(rect.right, lessThanOrEqualTo(64.001));
      expect(rect.bottom, lessThanOrEqualTo(40.001));
    }
  });

  test('paneAt hits the pane under the point', () {
    const box = Size(64, 40);
    expect(paneAt(panes, box, const Offset(10, 10)), 0);
    expect(paneAt(panes, box, const Offset(50, 5)), 1);
    expect(paneAt(panes, box, const Offset(50, 18)), 2);
    expect(paneAt(panes, box, const Offset(63.9, 39.9)), isNull); // below the scaled window
  });

  testWidgets('MiniMap paints every pane and fills the current one', (tester) async {
    int? tapped;
    await tester.pumpWidget(Center(
      child: MiniMap(panes: panes, currentId: 1, onTapPane: (id) => tapped = id),
    ));
    final box = find.byType(CustomPaint).last;
    expect(
      tester.renderObject(box),
      paints
        ..rrect(style: PaintingStyle.fill)
        ..rrect(style: PaintingStyle.stroke)
        ..rrect(color: accent)
        ..rrect(style: PaintingStyle.fill)
        ..rrect(style: PaintingStyle.stroke),
    );
    final topLeft = tester.getTopLeft(find.byType(MiniMap));
    await tester.tapAt(topLeft + const Offset(50, 18));
    expect(tapped, 2);
  });
}
