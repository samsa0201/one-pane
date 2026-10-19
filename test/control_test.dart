import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/control.dart';

/// Client fed by a controller; records written commands.
(TmuxClient, StreamController<List<int>>, List<String>) mk() {
  final ctl = StreamController<List<int>>();
  final written = <String>[];
  return (TmuxClient(ctl.stream, written.add), ctl, written);
}

void main() {
  test('decodeOutput', () {
    expect(decodeOutput(r'\015\012'), [13, 10]);
    expect(decodeOutput(r'\033[m'), [27, 0x5b, 0x6d]);
    expect(decodeOutput(r'a\134b'), [0x61, 0x5c, 0x62]);
    expect(decodeOutput('😀'), utf8.encode('😀'));
    expect(utf8.decode(decodeOutput(r'x\015é')), 'x\ré');
  });

  test('fixture: replies FIFO, errors, events', () async {
    final (c, ctl, _) = mk();
    final events = <TmuxEvent>[];
    c.events.listen(events.add);
    final r1 = c.cmd('list-sessions');
    final r2 = c.cmd('list-windows');
    final r3 = c.cmd('list-panes');
    final r4 = c.cmd('select-window -t 0');
    final r5 = c.cmd('select-window -t 0');
    final r6 = c.cmd('refresh-client');
    final bytes = File('test/fixtures/control_mode_sample.txt').readAsBytesSync();
    // feed in awkward chunks to exercise line splitting
    for (var i = 0; i < bytes.length; i += 7) {
      ctl.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7));
    }
    expect(await r1, [r'$1 other 1', r'$0 work 2']);
    expect((await r2).length, 2);
    expect((await r3).length, 3);
    await expectLater(r4, throwsA(isA<TmuxError>().having((e) => e.lines, 'lines', ["can't find window: 0"])));
    await expectLater(r5, throwsA(isA<TmuxError>()));
    expect(await r6, isEmpty);
    await ctl.close();
    await Future<void>.delayed(Duration.zero);

    final sc = events.whereType<SessionChangedEvent>().single;
    expect((sc.sessionId, sc.name), (0, 'work'));
    final out = events.whereType<OutputEvent>().toList();
    expect(out.where((e) => e.paneId == 2), isNotEmpty);
    final p0 = utf8.decode(out.where((e) => e.paneId == 0).expand((e) => e.bytes).toList());
    expect(p0, contains('Welcome to fish, the friendly interactive shell\r\n'));
    expect(p0, contains('\x1b\\')); // \134 → backslash
    final p1 = utf8.decode(out.where((e) => e.paneId == 1).expand((e) => e.bytes).toList());
    expect(p1, contains('Split vertical ▯'));
    expect(events.whereType<WindowsChangedEvent>().length, 2); // renamed + session-window-changed
    expect(events.last, isA<ExitEvent>());
  });

  test('notifications', () async {
    final (c, ctl, _) = mk();
    final events = <TmuxEvent>[];
    c.events.listen(events.add);
    ctl.add(utf8.encode([
      '%layout-change @3 8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1} 8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1} *',
      '%window-add @4',
      '%window-close @4',
      '%unlinked-window-close @5',
      '%sessions-changed',
      '%window-pane-changed @3 %7',
      '%session-changed \$2 my session',
      '%something-new foo',
      '%exit detached',
      '',
    ].join('\n')));
    await ctl.close();
    await Future<void>.delayed(Duration.zero);
    final l = events[0] as LayoutEvent;
    expect((l.windowId, l.layout), (3, '8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1}'));
    expect(events.whereType<WindowsChangedEvent>().length, 3);
    expect(events.whereType<SessionsChangedEvent>().length, 1);
    final a = events.whereType<ActivePaneEvent>().single;
    expect((a.windowId, a.paneId), (3, 7));
    expect(events.whereType<SessionChangedEvent>().single.name, 'my session');
    expect((events.last as ExitEvent).reason, 'detached');
  });

  test('helpers build commands and parse replies', () async {
    final (c, ctl, w) = mk();
    void reply(List<String> lines) =>
        ctl.add(utf8.encode('%begin 1 1 1\n${lines.map((l) => '$l\n').join()}%end 1 1 1\n'));

    final s = c.listSessions();
    reply([r'$0 1 2 work', r'$1 0 1 my other']);
    final ss = await s;
    expect(w.last, "list-sessions -F '#{session_id} #{session_attached} #{session_windows} #{session_name}'\n");
    expect((ss[1].id, ss[1].name, ss[1].windows, ss[1].attached), (1, 'my other', 1, false));
    expect(ss[0].attached, true);

    final lw = c.listWindows();
    reply([
      '@1 2 0 0 %2 cbff,160x48,0,0,2 cbff,160x48,0,0,2 logs x',
      '@0 1 1 1 %1 8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1} 1c2f,160x48,0,0,1 fish',
    ]);
    final ws = await lw;
    expect(w.last, startsWith('list-windows -F '));
    expect(ws.map((x) => x.index), [1, 2]);
    expect((ws[0].id, ws[0].active, ws[0].zoomed, ws[0].activePane, ws[0].name), (0, true, true, 1, 'fish'));
    expect(ws[0].panes.map((p) => p.id), [0, 1]);
    expect(ws[0].visiblePanes.map((p) => (p.id, p.w, p.h)), [(1, 160, 48)]);
    expect(ws[1].visiblePanes.single.id, 2);
    expect(ws[1].name, 'logs x');

    final sb = c.sendBytes(3, List.generate(300, (i) => i & 0xff));
    reply([]);
    reply([]);
    await sb;
    expect(w[w.length - 2], startsWith('send-keys -t %3 -H 00 01 02'));
    expect(w[w.length - 2].trim().split(' ').length, 4 + 256);
    expect(w.last.trim().split(' ').length, 4 + 44);

    final cp = c.capturePane(3);
    reply(['line1', '\x1b[31mred', '', '']);
    expect(await cp, 'line1\r\n\x1b[31mred');
    expect(w.last, 'capture-pane -p -e -J -t %3\n');

    final cu = c.cursor(3);
    reply(['5 7']);
    expect(await cu, (5, 7));

    for (final (f, want) in [
      (() => c.selectPane(4), 'select-pane -t %4'),
      (() => c.selectPane(4, keepZoom: true), 'select-pane -Z -t %4'),
      (() => c.zoom(4), "if -F -t %4 '#{?window_zoomed_flag,,1}' 'resize-pane -Z -t %4'"),
      (() => c.unzoom(2), "if -F -t @2 '#{window_zoomed_flag}' 'resize-pane -Z -t @2'"),
      (() => c.setClientSize(50, 40), 'refresh-client -C 50x40'),
      (() => c.ignoreSize(true), 'refresh-client -f ignore-size'),
      (() => c.ignoreSize(false), 'refresh-client -f !ignore-size'),
    ]) {
      final r = f();
      reply([]);
      await r;
      expect(w.last, '$want\n');
    }

    final ns = c.newSession("it's");
    reply([]);
    await Future<void>.delayed(Duration.zero); // switch-client is sent after new-session replies
    reply([]);
    await ns;
    expect(w[w.length - 2], "new-session -d -s 'it'\\''s'\n");
    expect(w.last, "switch-client -t 'it'\\''s'\n");

    final pending = expectLater(
        c.cmd('list-panes'), throwsA(isA<TmuxError>().having((e) => e.lines, 'lines', ['closed'])));
    await c.close();
    expect(w.last, 'detach-client\n');
    await pending;
  });
}
