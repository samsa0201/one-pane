import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/layout.dart';
import 'package:tmux_pocket/ui/joystick.dart';

void main() {
  test('stickDir: literal direction, dead zone', () {
    expect(stickDir(const Offset(10, 5)), isNull);
    expect(stickDir(const Offset(30, 10)), Dir.right);
    expect(stickDir(const Offset(-30, 10)), Dir.left);
    expect(stickDir(const Offset(5, -30)), Dir.up);
    expect(stickDir(const Offset(5, 30)), Dir.down);
  });

  testWidgets('a short push is ignored, a push past the dead zone moves on release', (tester) async {
    final moves = <Dir>[];
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(child: Joystick(available: const {Dir.right}, onMove: moves.add, onTap: () => taps++)),
    ));
    await tester.drag(find.byType(Joystick), const Offset(25, 0)); // pan starts after slop: knob < dead zone
    expect(moves, isEmpty);
    final g = await tester.startGesture(tester.getCenter(find.byType(Joystick)));
    await g.moveBy(const Offset(0, -20));
    await g.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(moves, isEmpty); // only on release
    await g.up();
    expect(moves, [Dir.up]);
    await tester.tap(find.byType(Joystick));
    expect(taps, 1);
  });
}
