// Drives a real tmux (separate -L socket, no user config) through TmuxClient.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/tmux/control.dart';
import 'package:tmux_pocket/tmux/layout.dart';

const sock = 'pocket-test';

Future<T> firstWhere<T extends TmuxEvent>(Stream<TmuxEvent> s, bool Function(T) ok) =>
    s.where((e) => e is T && ok(e)).cast<T>().first.timeout(const Duration(seconds: 5));

void main() {
  late Process proc;
  late TmuxClient c;

  setUp(() async {
    await Process.run('tmux', ['-L', sock, 'kill-server']);
    // env -u TMUX: we may be running inside the user's tmux; SHELL=/bin/sh for predictable output.
    proc = await Process.start('env', [
      '-u', 'TMUX', 'SHELL=/bin/sh', //
      'tmux', '-L', sock, '-f', '/dev/null', '-C', 'new-session', '-A', '-s', 't', '-x', '120', '-y', '40',
    ]);
    c = TmuxClient(proc.stdout, (s) => proc.stdin.add(utf8.encode(s)));
  });

  tearDown(() async {
    await c.close();
    await Process.run('tmux', ['-L', sock, 'kill-server']);
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      proc.kill();
      return -1;
    });
  });

  test('live tmux control mode', () async {
    var ws = await c.listWindows();
    expect(ws, hasLength(1));
    expect(ws[0].panes, hasLength(1));
    final p0 = ws[0].activePane;
    expect(ws[0].panes.single.id, p0);

    final ss = await c.listSessions();
    expect(ss.single.name, 't');
    expect(ss.single.attached, true);

    final layout = firstWhere<LayoutEvent>(c.events, (e) => e.windowId == ws[0].id);
    await c.split(p0, horizontal: true);
    expect(parseLayout((await layout).layout), hasLength(2));
    ws = await c.listWindows();
    expect(ws[0].panes, hasLength(2));
    final p1 = ws[0].panes.firstWhere((p) => p.id != p0).id;
    expect(neighbor(ws[0].panes, p0, Dir.right), p1);
    expect(neighbor(ws[0].panes, p1, Dir.left), p0);
    expect(neighbor(ws[0].panes, p0, Dir.left), isNull);

    final buf = <int>[];
    final sub = c.events.listen((e) {
      if (e is OutputEvent && e.paneId == p1) buf.addAll(e.bytes);
    });
    await c.sendBytes(p1, utf8.encode('echo pocket\$((6*7))\r'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!utf8.decode(buf, allowMalformed: true).contains('pocket42') && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
    expect(utf8.decode(buf, allowMalformed: true), contains('pocket42'));

    final screen = await c.capturePane(p1);
    expect(screen, contains('pocket42'));
    expect(screen.split('\r\n').length, lessThanOrEqualTo(ws[0].panes.firstWhere((p) => p.id == p1).h));
    final (cx, cy) = await c.cursor(p1);
    expect(cx, greaterThanOrEqualTo(0));
    expect(cy, greaterThan(0));

    // phone mode: client size counts, zoom keeps the shown pane at the full client size
    await c.ignoreSize(false);
    await c.setClientSize(50, 30);
    await c.zoom(p1);
    await c.zoom(p1); // idempotent: must not toggle back
    var w = (await c.listWindows())[0];
    expect(w.zoomed, true);
    expect(w.panes, hasLength(2)); // window_layout: unzoomed geometry
    expect(w.sizeOf(p1)!.w, 50); // visible layout: zoomed pane fills the client
    expect(w.sizeOf(p1)!.h, 30); // control clients have no status line
    await c.selectPane(p0, keepZoom: true);
    w = (await c.listWindows())[0];
    expect((w.zoomed, w.activePane), (true, p0));
    await c.unzoom(w.id);
    await c.unzoom(w.id); // idempotent
    expect((await c.listWindows())[0].zoomed, false);
    await c.ignoreSize(true);

    await expectLater(c.cmd('select-window -t @999'), throwsA(isA<TmuxError>()));

    await c.newWindow();
    expect(await c.listWindows(), hasLength(2));

    await c.newSession("it's mine");
    expect((await c.listSessions()).map((s) => s.name), containsAll(['t', "it's mine"]));
  });
}
