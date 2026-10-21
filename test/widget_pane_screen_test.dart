// PaneScreen against a fake tmux: scripted control-mode replies, recorded commands.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tmux_pocket/tmux/control.dart';
import 'package:tmux_pocket/ui/joystick.dart';
import 'package:tmux_pocket/ui/minimap.dart';
import 'package:tmux_pocket/ui/pane_screen.dart';
import 'package:tmux_pocket/ui/settings_screen.dart';
import 'package:xterm/xterm.dart';

const layout = '7f31,160x48,0,0{80x48,0,0,0,79x48,81,0[79x24,81,0,1,79x23,81,25,2]}';
var curLayout = layout; // what list-windows reports
var modes = '0 0 0';
var silent = false;
var screen = ['hello']; // capture-pane of the visible screen // the fake server stops answering (dead connection) // alternate_on mouse_any_flag mouse_sgr_flag of every pane

/// Fake tmux: every command gets `%begin` / scripted lines / `%end`. The controller is tmux's stdout.
(TmuxClient, List<String>, StreamController<List<int>>) fakeTmux({bool twoWindows = false}) {
  final out = StreamController<List<int>>();
  final cmds = <String>[];
  var n = 0;
  List<String> replyFor(String c) => switch (c) {
        _ when c.startsWith('list-windows -t') => ['0 1 editor', '1 2 server'],
        _ when c.startsWith('list-windows') => [
            '@1 0 1 0 %0 $curLayout $curLayout main',
            if (twoWindows) '@2 1 0 0 %5 b25f,160x48,0,0,5 b25f,160x48,0,0,5 logs',
          ],
        _ when c.startsWith('list-sessions') => [r'$0 1 1 main', r'$1 0 2 work'],
        _ when c.startsWith('list-panes') => ['%0 fish', '%1 vim', '%2 htop', '%5 tail'],
        _ when c.startsWith('capture-pane') && c.contains(' -S ') => ['old line 1', 'old line 2'],
        _ when c.startsWith('capture-pane') => screen,
        _ when c.contains('alternate_on') => [modes],
        _ when c.startsWith('display') => ['0 0'],
        _ => [],
      };
  final client = TmuxClient(out.stream, (data) {
    final c = data.trim();
    cmds.add(c);
    if (c == 'detach-client' || silent) return;
    n++;
    out.add(utf8.encode('%begin 1 $n 1\n${replyFor(c).map((l) => '$l\n').join()}%end 1 $n 1\n'));
  });
  return (client, cmds, out);
}

late StreamController<List<int>> _out; // stdout of the last pumpScreen's fake tmux

Future<List<String>> pumpScreen(WidgetTester tester,
    {bool twoWindows = false,
    Future<(Null, TmuxClient)> Function()? reconnect,
    int? initialPane,
    void Function(String, int)? onPlace}) async {
  SharedPreferences.setMockInitialValues({});
  resetSettings();
  curLayout = layout;
  silent = false;
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final (client, cmds, out) = fakeTmux(twoWindows: twoWindows);
  _out = out;
  await tester.pumpWidget(MaterialApp(home: PaneScreen(
          client: client, session: 'main', reconnect: reconnect, initialPane: initialPane, onPlace: onPlace)));
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
  testWidgets('after the capture the pen is default: bare characters are not in its last colour',
      (tester) async {
    screen = ['\x1b[38;5;246mgrey placeholder'];
    addTearDown(() => screen = ['hello']);
    await pumpScreen(tester);
    final term = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    _out.add(utf8.encode('%output %0 \\033[2;1HX\n')); // Claude Code: cursor move + one char, no SGR
    await tester.pump();
    final row = term.buffer.lines[term.buffer.scrollBack + 1];
    expect(String.fromCharCode(row.getCodePoint(0)), 'X');
    expect(row.getForeground(0), term.buffer.lines[term.buffer.scrollBack + 2].getForeground(0)); // default
    expect(row.getForeground(0), isNot(term.buffer.lines[term.buffer.scrollBack].getForeground(0)));
  });

  testWidgets('a resized pane is re-captured from tmux, old screen cleared', (tester) async {
    final cmds = await pumpScreen(tester);
    final term = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    _out.add(utf8.encode('%output %0 \\033[20;5Hstale junk\n'));
    await tester.pump();
    final before = cmds.where((c) => c.startsWith('capture-pane -p -e -J -t %0')).length;
    curLayout = '7f31,140x48,0,0{60x48,0,0,0,79x48,61,0[79x24,61,0,1,79x23,61,25,2]}';
    _out.add(utf8.encode('%layout-change @1 $curLayout $curLayout *\n'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(term.viewWidth, 60);
    expect(cmds.where((c) => c.startsWith('capture-pane -p -e -J -t %0')).length, before + 1);
    final lines = [for (var i = 0; i < term.viewHeight; i++) term.buffer.lines[term.buffer.scrollBack + i].toString().trim()];
    expect(lines.first, 'hello');
    expect(lines.where((l) => l.contains('junk')), isEmpty);
  });

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

  testWidgets('joystick: push right and let go moves to the right neighbour, no history pull', (tester) async {
    final cmds = await pumpScreen(tester);
    final stick = find.byType(Joystick);
    await tester.drag(stick, const Offset(0, 80)); // down from %0: window edge, and not a pull to history
    await tester.pumpAndSettle();
    expect(cmds.where((c) => c.startsWith('select-pane') || c.contains('capture-pane -p -e -J -S')), isEmpty);
    await tester.drag(stick, const Offset(60, 5));
    await tester.pumpAndSettle();
    expect(cmds, contains('select-pane -Z -t %1'));
  });

  testWidgets('sheet: another session opens to its windows; tapping one goes there', (tester) async {
    final cmds = await pumpScreen(tester);
    await tester.tap(find.text('main')); // session chip → switcher
    await tester.pumpAndSettle();
    await tester.tap(find.text('work'));
    await tester.pumpAndSettle();
    expect(cmds, contains("list-windows -t 'work' -F '#{window_index} #{window_panes} #{window_name}'"));
    await tester.tap(find.text('server').last);
    await tester.pumpAndSettle();
    expect(cmds, containsAllInOrder(["select-window -t 'work:1'", "switch-client -t 'work'"]));
  });

  testWidgets('alternate screen: a one-finger drag scrolls the app (SGR wheel or arrow keys)', (tester) async {
    modes = '1 1 1';
    addTearDown(() => modes = '0 0 0');
    final cmds = await pumpScreen(tester);
    await tester.dragFrom(const Offset(150, 300), const Offset(0, 200)); // finger down = wheel up
    await tester.pumpAndSettle();
    final wheelUp = cmds.where((c) => c.startsWith('send-keys -t %0 -H 1b 5b 3c 36 34 3b')).length;
    expect(wheelUp, greaterThan(3));
    expect(find.text('Back to live'), findsNothing); // no history view on the alt screen

    modes = '1 0 0';
    await tester.dragFrom(const Offset(150, 500), const Offset(0, -5)); // a touch refreshes the modes
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(150, 500), const Offset(0, -200)); // finger up = later = arrow down
    await tester.pumpAndSettle();
    expect(cmds.where((c) => c == 'send-keys -t %0 -H 1b 5b 42' || c == 'send-keys -t %0 -H 1b 4f 42'),
        isNotEmpty);
  });

  testWidgets('main screen: dragging up at the live bottom does nothing', (tester) async {
    final cmds = await pumpScreen(tester);
    await tester.dragFrom(const Offset(150, 500), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(cmds.where((c) => c.contains('capture-pane -p -e -J -S') || c.startsWith('send-keys')), isEmpty);
  });

  testWidgets('opens on the remembered pane and reports where the user goes', (tester) async {
    final places = <(String, int)>[];
    final cmds = await pumpScreen(tester, initialPane: 2, onPlace: (s, p) => places.add((s, p)));
    expect(cmds, contains('select-pane -Z -t %2'));
    expect(places.last, ('main', 2));
    await twoFingerSwipe(tester, const Offset(0, 150)); // up from %2 → %1
    expect(places.last, ('main', 1));
  });

  testWidgets('a remembered pane that is gone falls back to the active one', (tester) async {
    final places = <(String, int)>[];
    final cmds = await pumpScreen(tester, initialPane: 42, onPlace: (s, p) => places.add((s, p)));
    expect(cmds.where((c) => c.startsWith('select-pane')), isEmpty);
    expect(places.last, ('main', 0));
  });

  testWidgets('swipe toward an edge without neighbour selects nothing', (tester) async {
    final cmds = await pumpScreen(tester);
    await twoFingerSwipe(tester, const Offset(150, 0)); // go left from %0: window edge
    await twoFingerSwipe(tester, const Offset(0, 150)); // go up: edge
    expect(cmds.where((c) => c.startsWith('select-pane')), isEmpty);
  });

  testWidgets('desk mode pref: ignore-size, no client size, no zoom', (tester) async {
    SharedPreferences.setMockInitialValues({});
    resetSettings();
    phoneMode.value = false;
    addTearDown(resetSettings);
    final (client, cmds, _) = fakeTmux();
    await tester.pumpWidget(MaterialApp(home: PaneScreen(client: client, session: 'main')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cmds, contains('refresh-client -f ignore-size'));
    expect(cmds.where((c) => c.startsWith('refresh-client -C') || c.startsWith('if ')), isEmpty);
  });

  testWidgets('fling the top bar left goes to the next window', (tester) async {
    final cmds = await pumpScreen(tester, twoWindows: true);
    await tester.fling(find.text('0 main'), const Offset(-200, 0), 1000);
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
    await tester.tap(find.text('main')); // switcher has the overview button
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Overview'));
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
    expect(cmds, contains('capture-pane -p -e -J -S -2000 -t %0'));
    expect(find.text('Back to live'), findsOneWidget);
    expect(find.byType(TerminalView), findsNWidgets(2));
    await tester.tap(find.text('Back to live'));
    await tester.pump();
    expect(find.text('Back to live'), findsNothing);

    await tester.dragFrom(const Offset(150, 300), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Back to live'), findsOneWidget);
    await tester.tap(find.text('Esc'));
    await tester.pump();
    expect(find.text('Back to live'), findsNothing);
  });

  testWidgets('connection drop: banner, reconnect, new client used', (tester) async {
    late List<String> cmds2;
    var calls = 0;
    await pumpScreen(tester, reconnect: () async {
      if (++calls == 1) throw Exception('network down'); // first, immediate try fails
      final (c, cmds, _) = fakeTmux();
      cmds2 = cmds;
      return (null, c);
    });
    await _out.close();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200)); // size debounce
    expect(find.text('Reconnecting…'), findsNothing);
    expect(cmds2, contains(startsWith('list-windows')));
    expect(cmds2, contains('capture-pane -p -e -J -t %0'));
    expect(cmds2, contains(startsWith('refresh-client -C ')));
    expect(cmds2, contains("if -F -t %0 '#{?window_zoomed_flag,,1}' 'resize-pane -Z -t %0'"));
  });

  testWidgets('heartbeat: latency in the bar; no reply in time reconnects', (tester) async {
    var calls = 0;
    final cmds = await pumpScreen(tester, reconnect: () async {
      calls++;
      return (null, fakeTmux().$1);
    });
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(cmds, contains('display -p ok'));

    silent = true; // connection silently dead
    await tester.pump(const Duration(seconds: 5)); // next beat
    await tester.pump(const Duration(seconds: 7));
    expect(calls, 0);
    silent = false; // (the new fake answers)
    await tester.pump(const Duration(seconds: 2)); // 8 s without a reply
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, 1);
  });

  testWidgets('reconnect gives up after 5 minutes: the card offers Try again', (tester) async {
    var calls = 0;
    await pumpScreen(tester, reconnect: () async {
      calls++;
      throw Exception('network down');
    });
    await _out.close();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(seconds: 10));
    }
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('network down'), findsOneWidget);
    final before = calls;
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(calls, before + 1);
    expect(find.text('Try again'), findsNothing);
    await tester.pumpWidget(const SizedBox()); // stop the new retry loop
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('latency shows in the switcher', (tester) async {
    await pumpScreen(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'\d+ ms')), findsOneWidget);
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
    await tester.tap(find.text('main')); // switcher has the overview button
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Overview'));
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
    await tester.drag(find.text('Esc'), const Offset(-500, 0)); // second page of keys
    await tester.pumpAndSettle();
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

void resetSettings() {
  phoneMode.value = true;
  joystickOn.value = true;
  followActive.value = true;
  termFontSize.value = 13;
}
