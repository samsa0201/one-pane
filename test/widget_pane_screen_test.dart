// PaneScreen against a fake tmux: scripted control-mode replies, recorded commands.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tmux_pocket/tmux/control.dart';
import 'package:tmux_pocket/ui/minimap.dart';
import 'package:tmux_pocket/ui/pane_screen.dart';
import 'package:xterm/xterm.dart';

const layout = '7f31,160x48,0,0{80x48,0,0,0,79x48,81,0[79x24,81,0,1,79x23,81,25,2]}';

/// Fake tmux: every command gets `%begin` / scripted lines / `%end`. The controller is tmux's stdout.
(TmuxClient, List<String>, StreamController<List<int>>) fakeTmux({bool twoWindows = false}) {
  final out = StreamController<List<int>>();
  final cmds = <String>[];
  var n = 0;
  List<String> replyFor(String c) => switch (c) {
        _ when c.startsWith('list-windows') => [
            '@1 0 1 0 %0 $layout $layout main',
            if (twoWindows) '@2 1 0 0 %5 b25f,160x48,0,0,5 b25f,160x48,0,0,5 logs',
          ],
        _ when c.startsWith('list-sessions') => [r'$0 1 1 main', r'$1 0 2 work'],
        _ when c.startsWith('list-panes') => ['%0 fish', '%1 vim', '%2 htop', '%5 tail'],
        _ when c.startsWith('capture-pane') && c.contains(' -S ') => ['old line 1', 'old line 2'],
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
  return (client, cmds, out);
}

late StreamController<List<int>> _out; // stdout of the last pumpScreen's fake tmux

Future<List<String>> pumpScreen(WidgetTester tester,
    {bool twoWindows = false, Future<(Null, TmuxClient)> Function()? reconnect}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final (client, cmds, out) = fakeTmux(twoWindows: twoWindows);
  _out = out;
  await tester.pumpWidget(MaterialApp(home: PaneScreen(client: client, session: 'main', reconnect: reconnect)));
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
    final (client, cmds, _) = fakeTmux();
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

  testWidgets('edge hints show the neighbour commands', (tester) async {
    await pumpScreen(tester);
    await tester.pump();
    expect(find.text('vim ›'), findsOneWidget); // %1 is right of %0
    expect(find.textContaining('‹'), findsNothing); // window edge
    expect(find.textContaining('˄'), findsNothing);
    expect(find.textContaining('˅'), findsNothing);
    final hint = find.ancestor(of: find.text('vim ›'), matching: find.byType(IgnorePointer)).first;
    expect(tester.widget<IgnorePointer>(hint).ignoring, true);
  });

  testWidgets('overview button opens the overview, picking a pane keeps the zoom', (tester) async {
    final cmds = await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pumpAndSettle();
    for (final id in ['%0', '%1', '%2']) {
      expect(find.text(id), findsOneWidget);
    }
    await tester.tap(find.text('%2'));
    await tester.pumpAndSettle();
    expect(cmds, contains('select-pane -Z -t %2'));
  });

  testWidgets('pulling down past the top shows tmux history; LIVE or a key dismisses it', (tester) async {
    final cmds = await pumpScreen(tester);
    await tester.dragFrom(const Offset(150, 300), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(cmds, contains('capture-pane -p -e -J -S -2000 -E -1 -t %0'));
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.byType(TerminalView), findsNWidgets(2));
    await tester.tap(find.text('LIVE'));
    await tester.pump();
    expect(find.text('LIVE'), findsNothing);

    await tester.dragFrom(const Offset(150, 300), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('LIVE'), findsOneWidget);
    await tester.tap(find.text('Esc'));
    await tester.pump();
    expect(find.text('LIVE'), findsNothing);
  });

  testWidgets('connection drop: banner, reconnect, new client used', (tester) async {
    late List<String> cmds2;
    var calls = 0;
    await pumpScreen(tester, reconnect: () async {
      calls++;
      final (c, cmds, _) = fakeTmux();
      cmds2 = cmds;
      return (null, c);
    });
    await _out.close();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(calls, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200)); // size debounce
    expect(find.text('Reconnecting…'), findsNothing);
    expect(cmds2, contains(startsWith('list-windows')));
    expect(cmds2, contains('capture-pane -p -e -J -t %0'));
    expect(cmds2, contains(startsWith('refresh-client -C ')));
    expect(cmds2, contains("if -F -t %0 '#{?window_zoomed_flag,,1}' 'resize-pane -Z -t %0'"));
  });

  testWidgets('killed session (%sessions-changed + %exit) does not reconnect', (tester) async {
    var calls = 0;
    await pumpScreen(tester, reconnect: () async {
      calls++;
      return (null, fakeTmux().$1);
    });
    _out.add(utf8.encode('%sessions-changed\n%exit\n'));
    await _out.close();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Reconnecting…'), findsNothing);
    expect(calls, 0);
    expect(find.text('Session ended'), findsOneWidget);
  });

  testWidgets('edge hints dim after 2 s and light up on touch', (tester) async {
    await pumpScreen(tester);
    double opacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(of: find.text('vim ›'), matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(), 0.15);
    final g = await tester.startGesture(const Offset(150, 400));
    await tester.pump();
    expect(opacity(), 1);
    await g.up();
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(), 0.15);
  });

  testWidgets('dragging from the minimap scrubs to a pane, not the window', (tester) async {
    final cmds = await pumpScreen(tester, twoWindows: true);
    final map = tester.getRect(find.byType(MiniMap));
    final g = await tester.startGesture(map.centerLeft + const Offset(8, 0)); // on %0
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(2, 1.5)); // toward the bottom-right
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('htop'), findsOneWidget); // overlay labels
    expect(find.text('fish'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('htop'), findsNothing);
    expect(cmds, contains('select-pane -Z -t %2'));
    expect(cmds, isNot(contains(startsWith('select-window'))));
  });

  testWidgets('overview Sessions button opens the session map', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.view_module));
    await tester.pumpAndSettle();
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('work'), findsOneWidget);
    expect(find.text('main · 3 panes'), findsOneWidget);
  });

  testWidgets('Paste sends the clipboard, bracketed when the pane enabled it', (tester) async {
    final cmds = await pumpScreen(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'a\nb'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.ensureVisible(find.text('Paste'));
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(cmds, contains('send-keys -t %0 -H 61 0d 62'));

    _out.add(utf8.encode('%output %0 \\033[?2004h\n'));
    await tester.pump();
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(cmds, contains('send-keys -t %0 -H 1b 5b 32 30 30 7e 61 0d 62 1b 5b 32 30 31 7e'));
  });
}
