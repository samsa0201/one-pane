import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/layout.dart';

String dump(List<PaneRect> ps) =>
    ps.map((p) => '${p.id}:${p.w}x${p.h}@${p.x},${p.y}').join(' ');

void main() {
  const two = '8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1}';
  const three = 'a1b2,160x48,0,0{80x48,0,0,0,79x48,81,0[79x24,81,0,1,79x23,81,25,3]}';

  test('single pane', () {
    expect(dump(parseLayout('cbff,160x48,0,0,2')), '2:160x48@0,0');
  });

  test('horizontal split', () {
    expect(dump(parseLayout(two)), '0:80x48@0,0 1:79x48@81,0');
  });

  test('vertical split, no checksum', () {
    expect(dump(parseLayout('80x49,0,0[80x24,0,0,4,80x24,0,25,5]')),
        '4:80x24@0,0 5:80x24@0,25');
  });

  test('nested', () {
    expect(dump(parseLayout(three)), '0:80x48@0,0 1:79x24@81,0 3:79x23@81,25');
  });

  test('garbage throws', () {
    for (final s in ['', 'abcd', '80x48,0,0', '80x48,0,0{80x48,0,0,1', '80x48,0,0,1junk']) {
      expect(() => parseLayout(s), throwsFormatException, reason: s);
    }
  });

  test('neighbor', () {
    final ps = parseLayout(three);
    expect(neighbor(ps, 3, Dir.left), 0);
    expect(neighbor(ps, 1, Dir.left), 0);
    expect(neighbor(ps, 0, Dir.right), 1);
    expect(neighbor(ps, 1, Dir.down), 3);
    expect(neighbor(ps, 3, Dir.up), 1);
    expect(neighbor(ps, 0, Dir.left), isNull);
    expect(neighbor(ps, 0, Dir.up), isNull);
    expect(neighbor(ps, 1, Dir.right), isNull);
    expect(neighbor(ps, 9, Dir.right), isNull);
    final two_ = parseLayout(two);
    expect(neighbor(two_, 0, Dir.right), 1);
    expect(neighbor(two_, 1, Dir.left), 0);
  });

  test('neighbor tie picks closest top', () {
    // right pane 2 spans both left panes equally? left: 0 (top) and 1 (bottom), equal heights.
    final ps = parseLayout('100x49,0,0{50x49,0,0[50x24,0,0,0,50x24,0,25,1],49x49,51,0,2}');
    expect(neighbor(ps, 2, Dir.left), 0);
  });

  test('neighbor prefers adjacent over far pane', () {
    // three columns: 0 | 1 | 2 ; from 2 left → 1, not 0
    final ps = parseLayout('92x10,0,0{30x10,0,0,0,30x10,31,0,1,30x10,62,0,2}');
    expect(neighbor(ps, 2, Dir.left), 1);
    expect(neighbor(ps, 0, Dir.right), 1);
  });
}
