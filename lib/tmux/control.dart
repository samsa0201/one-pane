/// tmux control mode (`tmux -C`) client: line parser, command replies, notifications.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'layout.dart';

/// Octal-unescapes a `%output` payload to raw bytes (non-escaped chars → their UTF-8 bytes).
List<int> decodeOutput(String escaped) => _unescape(utf8.encode(escaped));

// Works on raw line bytes so a UTF-8 char split across two %output lines survives.
List<int> _unescape(List<int> b) {
  final out = <int>[];
  for (var i = 0; i < b.length; i++) {
    if (b[i] == 0x5c && i + 3 < b.length && _oct(b[i + 1]) && _oct(b[i + 2]) && _oct(b[i + 3])) {
      out.add(((b[i + 1] - 0x30) << 6 | (b[i + 2] - 0x30) << 3 | (b[i + 3] - 0x30)) & 0xff);
      i += 3;
    } else {
      out.add(b[i]);
    }
  }
  return out;
}

bool _oct(int c) => c >= 0x30 && c <= 0x37;

sealed class TmuxEvent {}

class OutputEvent extends TmuxEvent {
  final int paneId;
  final List<int> bytes;
  OutputEvent(this.paneId, this.bytes);
}

class LayoutEvent extends TmuxEvent {
  final int windowId;
  final String layout;
  LayoutEvent(this.windowId, this.layout);
}

/// add/close/rename/session-window-changed → refresh the window list.
class WindowsChangedEvent extends TmuxEvent {}

class SessionChangedEvent extends TmuxEvent {
  final int sessionId;
  final String name;
  SessionChangedEvent(this.sessionId, this.name);
}

class SessionsChangedEvent extends TmuxEvent {}

class ActivePaneEvent extends TmuxEvent {
  final int windowId;
  final int paneId;
  ActivePaneEvent(this.windowId, this.paneId);
}

class ExitEvent extends TmuxEvent {
  final String? reason;
  ExitEvent(this.reason);
}

class SessionInfo {
  final int id;
  final String name;
  final int windows;
  final bool attached;
  const SessionInfo(this.id, this.name, this.windows, this.attached);
}

class WindowInfo {
  final int id;
  final int index;
  final String name;
  final bool active;
  final List<PaneRect> panes;
  final int activePane;
  final bool zoomed;

  /// From #{window_visible_layout}: while zoomed, only the zoomed pane at its real (full-window) size.
  final List<PaneRect> visiblePanes;
  const WindowInfo(this.id, this.index, this.name, this.active, this.panes, this.activePane, this.zoomed,
      [this.visiblePanes = const []]);

  /// Real size of pane [id]: its visible rect if shown, else its layout rect.
  PaneRect? sizeOf(int id) =>
      visiblePanes.where((p) => p.id == id).firstOrNull ?? panes.where((p) => p.id == id).firstOrNull;
}

class TmuxError implements Exception {
  final List<String> lines;
  TmuxError(this.lines);
  @override
  String toString() => 'TmuxError(${lines.join('\n')})';
}

/// Shell-style single quoting for tmux command arguments.
String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// `$3` / `@3` / `%3` → 3.
int _id(String s) => int.parse(s.substring(1));

class TmuxClient {
  final void Function(String data) _write;
  final _events = StreamController<TmuxEvent>.broadcast();
  final _pending = Queue<Completer<List<String>>>();
  final _buf = <int>[];
  List<String>? _block; // lines of the open %begin block
  bool _blockIsOurs = false;
  bool _closed = false;

  /// [write] receives `<command>\n` strings for tmux's stdin.
  TmuxClient(Stream<List<int>> stdout, void Function(String data) write) : _write = write {
    stdout.listen(_onData, onDone: _failPending, onError: (_) => _failPending());
  }

  Stream<TmuxEvent> get events => _events.stream;

  Future<List<String>> cmd(String command) {
    if (_closed) return Future.error(TmuxError(['closed']));
    final c = Completer<List<String>>();
    _pending.add(c);
    _write('$command\n');
    return c.future;
  }

  void _onData(List<int> chunk) {
    for (final b in chunk) {
      if (b != 0x0a) {
        _buf.add(b);
        continue;
      }
      if (_buf.isNotEmpty && _buf.last == 0x0d) _buf.removeLast();
      _line(_buf);
      _buf.clear();
    }
  }

  void _line(List<int> bytes) {
    final block = _block;
    // %output payload is decoded from raw bytes; everything else is text.
    if (block == null && _startsWith(bytes, '%output %')) {
      final sp = bytes.indexOf(0x20, 9);
      if (sp < 0) return;
      final pane = int.tryParse(ascii.decode(bytes.sublist(9, sp), allowInvalid: true));
      if (pane != null) _events.add(OutputEvent(pane, _unescape(bytes.sublist(sp + 1))));
      return;
    }
    final line = utf8.decode(bytes, allowMalformed: true);
    if (block != null) {
      if (line.startsWith('%end ') || line.startsWith('%error ')) {
        _block = null;
        if (_blockIsOurs && _pending.isNotEmpty) {
          final c = _pending.removeFirst();
          line.startsWith('%end ') ? c.complete(block) : c.completeError(TmuxError(block));
        }
      } else {
        block.add(line);
      }
      return;
    }
    final parts = line.split(' ');
    String rest(int n) => parts.skip(n).join(' ');
    switch (parts[0]) {
      case '%begin':
        _block = [];
        _blockIsOurs = parts.length > 3 && (int.tryParse(parts[3]) ?? 0) & 1 == 1;
      case '%layout-change' when parts.length > 2:
        _events.add(LayoutEvent(_id(parts[1]), parts[2]));
      case '%window-add' || '%window-close' || '%unlinked-window-close' || '%window-renamed' ||
            '%session-window-changed':
        _events.add(WindowsChangedEvent());
      case '%session-changed' when parts.length > 2:
        _events.add(SessionChangedEvent(_id(parts[1]), rest(2)));
      case '%sessions-changed':
        _events.add(SessionsChangedEvent());
      case '%window-pane-changed' when parts.length > 2:
        _events.add(ActivePaneEvent(_id(parts[1]), _id(parts[2])));
      case '%exit':
        _events.add(ExitEvent(parts.length > 1 ? rest(1) : null));
    }
  }

  static bool _startsWith(List<int> b, String p) {
    if (b.length < p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (b[i] != p.codeUnitAt(i)) return false;
    }
    return true;
  }

  void _failPending() {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(TmuxError(['closed']));
    }
  }

  Future<List<SessionInfo>> listSessions() async {
    final lines = await cmd(
        "list-sessions -F '#{session_id} #{session_attached} #{session_windows} #{session_name}'");
    return [
      for (final l in lines)
        if (l.split(' ') case [final id, final att, final win, ...final name])
          SessionInfo(_id(id), name.join(' '), int.parse(win), int.parse(att) > 0),
    ];
  }

  /// Windows of the attached session, sorted by index.
  Future<List<WindowInfo>> listWindows() async {
    final lines = await cmd("list-windows -F '#{window_id} #{window_index} #{window_active} "
        "#{window_zoomed_flag} #{pane_id} #{window_layout} #{window_visible_layout} #{window_name}'");
    final ws = [
      for (final l in lines)
        if (l.split(' ')
            case [final id, final idx, final act, final zoom, final pane, final layout, final vis, ...final name])
          WindowInfo(_id(id), int.parse(idx), name.join(' '), act == '1', parseLayout(layout), _id(pane),
              zoom == '1', parseLayout(vis)),
    ]..sort((a, b) => a.index.compareTo(b.index));
    return ws;
  }

  Future<void> sendBytes(int paneId, List<int> bytes) async {
    final cmds = <Future<List<String>>>[];
    for (var i = 0; i < bytes.length; i += 256) {
      final hex = bytes
          .sublist(i, i + 256 > bytes.length ? bytes.length : i + 256)
          .map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0'))
          .join(' ');
      cmds.add(cmd('send-keys -t %$paneId -H $hex'));
    }
    await Future.wait(cmds);
  }

  /// Visible screen with escapes, lines joined with \r\n (trailing empty lines dropped).
  Future<String> capturePane(int paneId) async {
    final lines = await cmd('capture-pane -p -e -J -t %$paneId');
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\r\n');
  }

  Future<(int, int)> cursor(int paneId) async {
    final l = (await cmd("display -p -t %$paneId '#{cursor_x} #{cursor_y}'")).first.split(' ');
    return (int.parse(l[0]), int.parse(l[1]));
  }

  /// keepZoom: `-Z`, a zoomed window stays zoomed (on the new pane).
  Future<void> selectPane(int paneId, {bool keepZoom = false}) =>
      cmd('select-pane ${keepZoom ? '-Z ' : ''}-t %$paneId');
  Future<void> selectWindow(int windowId) => cmd('select-window -t @$windowId');
  Future<void> switchSession(String name) => cmd('switch-client -t ${_q(name)}');
  Future<void> newWindow() => cmd('new-window');

  /// horizontal: new pane beside (left/right, `-h`); otherwise below.
  Future<void> split(int paneId, {required bool horizontal}) =>
      cmd('split-window ${horizontal ? '-h' : '-v'} -t %$paneId');
  Future<void> killPane(int paneId) => cmd('kill-pane -t %$paneId');
  Future<void> toggleZoom(int paneId) => cmd('resize-pane -Z -t %$paneId');

  /// Zooms the pane unless its window is already zoomed (checked by tmux, so no race with our cache).
  Future<void> zoom(int paneId) =>
      cmd("if -F -t %$paneId '#{?window_zoomed_flag,,1}' 'resize-pane -Z -t %$paneId'");

  /// Unzooms the window if it is zoomed.
  Future<void> unzoom(int windowId) =>
      cmd("if -F -t @$windowId '#{window_zoomed_flag}' 'resize-pane -Z -t @$windowId'");

  /// This client's size in cells (only counts while ignore-size is off).
  Future<void> setClientSize(int cols, int rows) => cmd('refresh-client -C ${cols}x$rows');

  /// on: tmux ignores this client's size when sizing windows.
  Future<void> ignoreSize(bool on) => cmd('refresh-client -f ${on ? '' : '!'}ignore-size');

  Future<void> newSession(String name) async {
    await cmd('new-session -d -s ${_q(name)}');
    await switchSession(name);
  }

  Future<void> close() async {
    if (_closed) return;
    _write('detach-client\n');
    _closed = true;
    _failPending();
  }
}
