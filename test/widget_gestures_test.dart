import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/layout.dart';
import 'package:tmux_pocket/ui/gestures.dart';

void main() {
  test('swipeDir: below threshold is null', () {
    expect(swipeDir(const Offset(30, 30)), isNull);
    expect(swipeDir(Offset.zero), isNull);
  });

  test('swipeDir: fingers move left reveals the right pane, and so on', () {
    expect(swipeDir(const Offset(-100, 10)), Dir.right);
    expect(swipeDir(const Offset(100, -10)), Dir.left);
    expect(swipeDir(const Offset(10, -100)), Dir.down);
    expect(swipeDir(const Offset(-10, 100)), Dir.up);
  });

  test('swipeDir: dominant axis wins', () {
    expect(swipeDir(const Offset(-70, 65)), Dir.right);
    expect(swipeDir(const Offset(-65, 70)), Dir.up);
  });
}
