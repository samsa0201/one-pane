// PaneScreen against a fake tmux: scripted control-mode replies, recorded commands.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tmux_pocket/tmux/control.dart';
import 'package:tmux_pocket/ui/pane_screen.dart';

const layout = '7f31,160x48,0,0{80x48,0,0,0,79x48,81,0[79x24,81,0,1,79x23,81,25,2]}';

/// Fake tmux: every command gets `%begin` / scripted lines / `%end`.
(TmuxClient, List<String>) fakeTmux({bool twoWindows = false}) {
  final out = StreamController<List<int>>();
  final cmds = <String>[];
  var n = 0;
  List<String> replyFor(String c) => switch (c) {
        _ when c.startsWith('list-windows') => [
            '@1 0 1 0 %0 $layout $layout main',
            if (twoWindows) '@2 1 0 0 %5 b25f,160x48,0,0,5 b25f,160x48,0,0,5 logs',
          ],
        _ when c.startsWith('list-sessions') => [r'$0 1 1 main'],
        _ when c.startsWith('capture-pane') => ['hello'],
        _ when c.startsWith('display') => ['0 0'],
        _ => [],
      };
  final client = TmuxClient(out.stream, (data) {
    final c = data.trim();
    cmds.add(c);
    if (c == 'detach-client') return;
    n++;
    out.add(utf8.encode('%begin 1 $n 1\n${replyFor(c).map((l) => '$l\n').join()}%end 1 $n 1\n'));
  });
  return (client, cmds);
}

Future<List<String>> pumpScreen(WidgetTester tester, {bool twoWindows = false}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final (client, cmds) = fakeTmux(twoWindows: twoWindows);
  await tester.pumpWidget(MaterialApp(home: PaneScreen(client: client, session: 'main')));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200)); // size debounce
  return cmds;
}

/// Two fingers 150 px apart moving together by [delta], in small steps (each finger's move is a separate
/// event, so big steps would look like a pinch).
Future<void> twoFingerSwipe(WidgetTester tester, Offset delta) async {
  const a = Offset(120, 400), b = Offset(270, 400);
  final g1 = await tester.startGesture(a, pointer: 1);
  final g2 = await tester.startGesture(b, pointer: 2);
  for (var i = 1; i <= 30; i++) {
    await g1.moveTo(a + delta * (i / 30));
    await g2.moveTo(b + delta * (i / 30));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g1.up();
  await g2.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phone mode: sizes the client, zooms the shown pane, keyboard hidden', (tester) async {
    final cmds = await pumpScreen(tester);
    expect(cmds, isNot(contains('refresh-client -f ignore-size')));
    final size = cmds.where((c) => c.startsWith('refresh-client -C ')).single;
    final m = RegExp(r'^refresh-client -C (\d+)x(\d+)$').firstMatch(size)!;
    final (cols, rows) = (int.parse(m[1]!), int.parse(m[2]!));
    // 392x873 logical px minus top bar and keys row; any monospace font at 13px
    expect(cols, inInclusiveRange(25, 70));
    expect(rows, inInclusiveRange(35, 70));
    expect(cmds, contains("if -F -t %0 '#{?window_zoomed_flag,,1}' 'resize-pane -Z -t %0'"));
    expect(tester.testTextInput.isVisible, false);
    expect(tester.testTextInput.hasAnyClients, false);
  });

  testWidgets('two-finger swipe left goes to the right neighbour', (tester) async {
    final cmds = await pumpScreen(tester);
    await twoFingerSwipe(tester, const Offset(-150, 0));
    expect(cmds, contains('select-pane -Z -t %1'));
  });

  testWidgets('swipe toward an edge without neighbour selects nothing', (tester) async {
    final cmds = await pumpScreen(tester);
    await twoFingerSwipe(tester, const Offset(150, 0)); // go left from %0: window edge
    await twoFingerSwipe(tester, const Offset(0, 150)); // go up: edge
    expect(cmds.where((c) => c.startsWith('select-pane')), isEmpty);
  });

  testWidgets('desk mode pref: ignore-size, no client size, no zoom', (tester) async {
    SharedPreferences.setMockInitialValues({'phoneMode': false});
    final (client, cmds) = fakeTmux();
    await tester.pumpWidget(MaterialApp(home: PaneScreen(client: client, session: 'main')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cmds, contains('refresh-client -f ignore-size'));
    expect(cmds.where((c) => c.startsWith('refresh-client -C') || c.startsWith('if ')), isEmpty);
  });

  testWidgets('fling the top bar left goes to the next window', (tester) async {
    final cmds = await pumpScreen(tester, twoWindows: true);
    await tester.fling(find.textContaining('0:main'), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(cmds, contains('select-window -t @2'));
  });
}
