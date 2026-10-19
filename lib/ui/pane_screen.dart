import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ParagraphBuilder, ParagraphConstraints;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../tmux/control.dart';
import '../tmux/layout.dart';
import 'gestures.dart';
import 'minimap.dart';
import 'overview.dart';

/// One tmux pane mirrored into an xterm Terminal.
class _Pane {
  final Terminal term;
  final FocusNode focus = FocusNode();
  late final ByteConversionSink decoder;
  int state = 0; // 0 capturing (drop output, capture has it), 1 awaiting cursor (buffer), 2 live
  final pending = <List<int>>[];
  _Pane(this.term);
}

class _FnSink implements Sink<String> {
  final void Function(String) fn;
  _FnSink(this.fn);
  @override
  void add(String s) => fn(s);
  @override
  void close() {}
}

/// Cell size TerminalView uses for [style] (same measurement as xterm's TerminalPainter, no text scaling).
Size terminalCellSize(TerminalStyle style) {
  const test = 'mmmmmmmmmm';
  final ts = style.toTextStyle();
  final b = ParagraphBuilder(ts.getParagraphStyle())
    ..pushStyle(ts.getTextStyle())
    ..addText(test);
  final p = b.build()..layout(const ParagraphConstraints(width: double.infinity));
  final size = Size(p.maxIntrinsicWidth / test.length, p.height);
  p.dispose();
  return size;
}

/// Whole cells of [cell] that fit in [area] (at least 10x5).
(int, int) fitCells(Size area, Size cell) =>
    (max(10, area.width ~/ cell.width), max(5, area.height ~/ cell.height));

class PaneScreen extends StatefulWidget {
  final SSHClient? ssh; // null in tests (fake tmux)
  final TmuxClient client;
  final String session;
  const PaneScreen({super.key, this.ssh, required this.client, required this.session});

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> with SingleTickerProviderStateMixin {
  TmuxClient get client => widget.client;

  late String _session = widget.session;
  List<WindowInfo> _windows = [];
  int? _winId, _paneId;
  bool _follow = true, _jumpToActive = false, _exited = false;
  final _panes = <int, _Pane>{};
  late final StreamSubscription<TmuxEvent> _sub;
  Timer? _reloadTimer;

  // Phone mode (default): tmux sizes the window to our cols×rows at font [_font] and the shown pane is
  // kept zoomed. Desk mode: ignore-size, real pane size, font = fit-to-width × [_zoom] (≥ 1).
  static const _phonePref = 'phoneMode';
  bool? _phoneMode; // null until the pref is loaded: render as phone, send nothing yet
  bool get _phone => _phoneMode ?? true;
  double _font = 13;
  double _zoom = 1;
  final _cells = <double, Size>{}; // font size → cell size
  (int, int)? _wantSize, _sentSize;
  Timer? _sizeTimer;
  final _zoomedByUs = <int>{}; // window ids we zoomed; unzoomed when leaving

  // input
  bool _ctrl = false, _alt = false, _writing = false;

  // transitions
  Offset _slideFrom = Offset.zero;
  late final AnimationController _bump =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
  Offset _bumpDir = Offset.zero;

  // two-finger gesture tracking (raw pointers, so TerminalView keeps its own gestures)
  final _ptrs = <int, Offset>{};
  Map<int, Offset>? _start;
  DateTime _t0 = DateTime.now();
  DateTime? _lastTwoTap;
  double _startZoom = 1, _startFont = 13, _scale = 1;
  bool _pinching = false;

  WindowInfo? get _window => _windows.where((w) => w.id == _winId).firstOrNull;
  List<PaneRect> get _rects => _window?.panes ?? const [];
  PaneRect? get _rect => _rects.where((p) => p.id == _paneId).firstOrNull;

  /// The shown pane's real size (zoomed: the visible-layout rect).
  PaneRect? get _termRect => _paneId == null ? null : _window?.sizeOf(_paneId!);

  Size _cell(double font) => _cells[font] ??= terminalCellSize(TerminalStyle(fontSize: font));

  @override
  void initState() {
    super.initState();
    _sub = client.events.listen(_onEvent);
    widget.ssh?.done.whenComplete(() => _exit('Connection closed'));
    _reload();
    () async {
      var phone = true;
      try {
        phone = (await SharedPreferences.getInstance()).getBool(_phonePref) ?? true;
      } catch (_) {}
      if (mounted) _setPhone(phone, persist: false);
    }();
  }

  void _setPhone(bool on, {bool persist = true}) {
    final was = _phoneMode;
    setState(() => _phoneMode = on);
    if (persist) SharedPreferences.getInstance().then((p) => p.setBool(_phonePref, on)).catchError((_) => true);
    if (on) {
      if (was == false) _run(client.ignoreSize(false));
      _sentSize = _wantSize = null; // next build re-sends -C
      _keepZoomed();
    } else {
      _run(client.ignoreSize(true));
      _unzoomOurs();
    }
  }

  /// Phone mode: called from build with the cells that fit; sends refresh-client -C after 150ms quiet.
  void _fitClient((int, int) size) {
    if (_phoneMode != true || size == _wantSize) return;
    _wantSize = size;
    _sizeTimer?.cancel();
    _sizeTimer = Timer(const Duration(milliseconds: 150), () {
      final s = _wantSize;
      if (_phoneMode != true || !mounted || s == null || s == _sentSize) return;
      _sentSize = s;
      _run(client.setClientSize(s.$1, s.$2));
    });
  }

  /// Phone mode: keep the shown pane zoomed so it gets the whole client size.
  void _keepZoomed() {
    final w = _window, id = _paneId;
    if (_phoneMode != true || w == null || id == null || w.panes.length < 2) return;
    if (!w.zoomed) _zoomedByUs.add(w.id);
    _run(client.zoom(id)); // tmux checks the zoom flag itself; our cache may be stale
  }

  /// Best effort: give the desktop its layout back.
  void _unzoomOurs() {
    for (final w in _zoomedByUs) {
      client.unzoom(w).then((_) {}, onError: (_) {});
    }
    _zoomedByUs.clear();
  }

  @override
  void dispose() {
    _sub.cancel();
    _reloadTimer?.cancel();
    _sizeTimer?.cancel();
    _bump.dispose();
    for (final p in _panes.values) {
      p.focus.dispose();
    }
    if (!_exited) _unzoomOurs(); // queued before detach-client, tmux runs them in order
    _exited = true;
    client.close().catchError((_) {});
    widget.ssh?.close();
    super.dispose();
  }

  // ---------- tmux events ----------

  void _onEvent(TmuxEvent e) {
    switch (e) {
      case OutputEvent():
        final p = _panes[e.paneId];
        if (p == null || p.state == 0) return;
        if (p.state == 1) {
          p.pending.add(e.bytes);
        } else {
          p.decoder.add(e.bytes);
        }
      case LayoutEvent() || WindowsChangedEvent():
        _scheduleReload();
      case SessionChangedEvent():
        _session = e.name;
        _jumpToActive = true;
        _scheduleReload();
      case ActivePaneEvent():
        if (_follow && e.windowId == _winId && e.paneId != _paneId) {
          _slideFrom = Offset.zero;
          _showPane(e.paneId);
        }
      case ExitEvent():
        _exit(e.reason ?? 'tmux exited');
      case SessionsChangedEvent():
        break;
    }
  }

  void _exit(String msg) {
    if (_exited || !mounted) return;
    _exited = true;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((r) => r.isFirst);
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 100), _reload);
  }

  Future<void> _reload() async {
    final List<WindowInfo> windows;
    try {
      windows = await client.listWindows();
    } catch (e) {
      return; // connection errors surface through ExitEvent / ssh.done
    }
    if (!mounted || windows.isEmpty) return;
    final before = (_winId, _paneId);
    setState(() {
      _windows = windows;
      final active = windows.where((w) => w.active).firstOrNull ?? windows.first;
      final oldWin = _winId;
      if (_winId == null || _window == null || _follow || _jumpToActive) _winId = active.id;
      _jumpToActive = false;
      final win = _window!;
      if (_winId != oldWin || _rect == null) _paneId = win.activePane;

      final alive = {for (final w in windows) for (final p in w.panes) p.id: p};
      _panes.removeWhere((id, p) {
        if (alive.containsKey(id)) return false;
        p.focus.dispose();
        return true;
      });
      for (final w in windows) {
        for (final r in w.visiblePanes) {
          alive[r.id] = r; // zoomed pane: real size
        }
      }
      for (final e in _panes.entries) {
        final r = alive[e.key]!;
        if (e.value.term.viewWidth != r.w || e.value.term.viewHeight != r.h) e.value.term.resize(r.w, r.h);
      }
      for (final p in win.panes) {
        _ensurePane(win.sizeOf(p.id)!);
      }
    });
    if ((_winId, _paneId) != before) _keepZoomed();
  }

  /// Creates the pane's Terminal at its tmux size and seeds it with capture-pane + cursor.
  void _ensurePane(PaneRect r) {
    if (_panes.containsKey(r.id)) return;
    final term = Terminal(maxLines: 5000);
    term.resize(r.w, r.h);
    final p = _Pane(term);
    p.decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_FnSink(_writer(term)));
    term.onOutput = (data) => _onInput(r.id, data);
    _panes[r.id] = p;
    () async {
      try {
        final screen = await client.capturePane(r.id);
        p.state = 1;
        final (x, y) = await client.cursor(r.id);
        _writer(term)('$screen\x1b[${y + 1};${x + 1}H');
      } catch (_) {
        // pane may have vanished; go live anyway
      }
      p.state = 2;
      for (final b in p.pending) {
        p.decoder.add(b);
      }
      p.pending.clear();
    }();
  }

  /// Writes to a terminal; replies the terminal emulator generates while parsing
  /// (DA, DSR...) are dropped: tmux already answered the program.
  void Function(String) _writer(Terminal t) => (s) {
        _writing = true;
        try {
          t.write(s);
        } finally {
          _writing = false;
        }
      };

  // ---------- input ----------

  void _onInput(int paneId, String data) {
    if (_writing) return;
    if (data.length == 1 && (_ctrl || _alt)) {
      var c = data.codeUnitAt(0);
      if (_ctrl) {
        if (c >= 0x61 && c <= 0x7a) {
          c -= 0x60; // a-z
        } else if (c >= 0x40 && c <= 0x5f) {
          c -= 0x40; // @ A-Z [ \ ] ^ _
        } else if (c == 0x20) {
          c = 0;
        }
      }
      data = (_alt ? '\x1b' : '') + String.fromCharCode(c);
      setState(() => _ctrl = _alt = false);
    }
    _run(client.sendBytes(paneId, utf8.encode(data)));
  }

  void _key(TerminalKey k) {
    final t = _panes[_paneId]?.term;
    if (t == null) return;
    final ctrl = _ctrl, alt = _alt;
    setState(() => _ctrl = _alt = false);
    t.keyInput(k, ctrl: ctrl, alt: alt);
  }

  void _text(String s) => _panes[_paneId]?.term.textInput(s);

  void _bytes(List<int> b) {
    if (_paneId != null) _run(client.sendBytes(_paneId!, b));
  }

  // then/onError, not catchError: helpers typed Future<void> are Future<List<String>> at runtime.
  void _run(Future<void> f) => f.then((_) {}, onError: (Object e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      });

  // ---------- navigation ----------

  void _showPane(int id, {bool select = false}) {
    if (!mounted) return;
    final hadKeyboard = _panes[_paneId]?.focus.hasFocus ?? false;
    setState(() {
      _paneId = id;
      final r = _termRect;
      if (r != null) _ensurePane(r);
    });
    if (hadKeyboard) WidgetsBinding.instance.addPostFrameCallback((_) => _panes[id]?.focus.requestFocus());
    if (select) _run(client.selectPane(id, keepZoom: _phone));
    _keepZoomed();
  }

  void _move(Dir d) {
    final id = _paneId;
    final n = id == null ? null : neighbor(_rects, id, d);
    if (n == null) {
      _bumpDir = dirOffset(d);
      _bump.forward(from: 0);
      HapticFeedback.lightImpact();
      return;
    }
    _slideFrom = dirOffset(d);
    _showPane(n, select: true);
  }

  void _selectWindow(int id, {Offset slideFrom = Offset.zero}) {
    final w = _windows.where((w) => w.id == id).firstOrNull;
    if (w == null) return;
    setState(() {
      _slideFrom = slideFrom;
      _winId = id;
      _paneId = w.activePane;
      for (final p in w.panes) {
        _ensurePane(w.sizeOf(p.id)!);
      }
    });
    _run(client.selectWindow(id));
    _keepZoomed();
  }

  void _stepWindow(int delta) {
    final i = _windows.indexWhere((w) => w.id == _winId);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _windows.length) {
      _bumpDir = Offset(delta.toDouble(), 0);
      _bump.forward(from: 0);
      HapticFeedback.lightImpact();
      return;
    }
    _selectWindow(_windows[j].id, slideFrom: Offset(delta.toDouble(), 0));
  }

  Future<void> _openOverview() async {
    final w = _window;
    if (w == null) return;
    w.panes.forEach(_ensurePane);
    final r = await Navigator.push<OverviewResult>(
      context,
      MaterialPageRoute(
        builder: (_) => WindowOverview(
            client: client, session: _session, window: w, currentPane: _paneId, terminals: {
          for (final e in _panes.entries) e.key: e.value.term,
        }),
      ),
    );
    if (r == null || !mounted) return;
    _slideFrom = Offset.zero;
    if (r.paneId != null) _showPane(r.paneId!, select: true);
    if (r.windowId != null) _selectWindow(r.windowId!);
    if (r.session != null) _run(client.switchSession(r.session!));
  }

  // ---------- two-finger gestures ----------

  Offset _focal(Map<int, Offset> m) => m.values.reduce((a, b) => a + b) / m.length.toDouble();
  double _spread(Map<int, Offset> m) {
    final v = m.values.toList();
    return max((v[0] - v[1]).distance, 1);
  }

  void _down(PointerDownEvent e) {
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length == 2) {
      _start = Map.of(_ptrs);
      _t0 = DateTime.now();
      _startZoom = _zoom;
      _startFont = _font;
      _scale = 1;
      _pinching = false;
    } else {
      _start = null; // 1 or 3+ fingers: not ours
    }
  }

  void _moveP(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.position;
    final s = _start;
    if (s == null || _ptrs.length != 2 || !s.keys.every(_ptrs.containsKey)) return;
    _scale = _spread(_ptrs) / _spread(s);
    if (!_pinching && (_scale - 1).abs() > 0.15) _pinching = true;
    if (!_pinching) return;
    setState(() {
      if (_phone) {
        _font = ((_startFont * _scale).clamp(8.0, 24.0) * 2).round() / 2; // 0.5 steps
      } else {
        _zoom = (_startZoom * _scale).clamp(1.0, 4.0);
      }
    });
  }

  void _up(PointerEvent e) {
    final s = _start;
    if (s != null && _ptrs.length == 2) {
      _start = null;
      final delta = _focal(_ptrs) - _focal(s);
      if (_pinching) {
        final atMin = _phone ? _startFont <= 8 : _startZoom <= 1.001;
        if (atMin && _scale < 0.7) _openOverview();
      } else if (swipeDir(delta) case final d?) {
        _move(d);
      } else if (DateTime.now().difference(_t0).inMilliseconds < 300 && delta.distance < 20) {
        final now = DateTime.now();
        if (_lastTwoTap != null && now.difference(_lastTwoTap!).inMilliseconds < 400) {
          _lastTwoTap = null;
          if (_paneId != null) _run(client.toggleZoom(_paneId!));
        } else {
          _lastTwoTap = now;
        }
      }
    }
    _ptrs.remove(e.pointer);
  }

  // ---------- sheets ----------

  void _sheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: FutureBuilder<List<SessionInfo>>(
            future: client.listSessions(),
            builder: (ctx, snap) => ListView(shrinkWrap: true, children: [
              const ListTile(dense: true, title: Text('Sessions')),
              for (final s in snap.data ?? const <SessionInfo>[])
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: Text(s.name),
                  subtitle: Text('${s.windows} windows'),
                  selected: s.name == _session,
                  onTap: () {
                    Navigator.pop(ctx);
                    if (s.name != _session) _run(client.switchSession(s.name));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New session'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final name = await _askName('New session');
                  if (name != null && name.isNotEmpty) _run(client.newSession(name));
                },
              ),
              const Divider(),
              const ListTile(dense: true, title: Text('Windows')),
              for (final w in _windows)
                ListTile(
                  leading: const Icon(Icons.web_asset),
                  title: Text('${w.index}:${w.name}'),
                  subtitle: Text('${w.panes.length} panes${w.zoomed ? ' · zoomed' : ''}'),
                  selected: w.id == _winId,
                  onTap: () {
                    Navigator.pop(ctx);
                    _selectWindow(w.id);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New window'),
                onTap: () {
                  Navigator.pop(ctx);
                  _run(client.newWindow());
                },
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Follow active pane'),
                subtitle: const Text('Jump when the pane changes from another client'),
                value: _follow,
                onChanged: (v) {
                  setState(() => _follow = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('Phone mode'),
                subtitle: const Text('Size tmux to this screen and zoom the shown pane. Off: mirror the '
                    'desktop size and scale the font'),
                value: _phone,
                onChanged: (v) {
                  _setPhone(v);
                  setSheet(() {});
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<String?> _askName(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  void _actions() {
    final id = _paneId;
    if (id == null) return;
    HapticFeedback.mediumImpact();
    void act(BuildContext ctx, Future<void> Function() f) {
      Navigator.pop(ctx);
      _run(f());
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
              leading: const Icon(Icons.vertical_split),
              title: const Text('Split ↔ (side by side)'),
              onTap: () => act(ctx, () => client.split(id, horizontal: true))),
          ListTile(
              leading: const Icon(Icons.horizontal_split),
              title: const Text('Split ↕ (stacked)'),
              onTap: () => act(ctx, () => client.split(id, horizontal: false))),
          ListTile(
              leading: const Icon(Icons.zoom_out_map),
              title: const Text('Toggle zoom'),
              onTap: () => act(ctx, () => client.toggleZoom(id))),
          ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('New window'),
              onTap: () => act(ctx, client.newWindow)),
          ListTile(
              leading: const Icon(Icons.close, color: Colors.redAccent),
              title: Text('Kill pane %$id'),
              onTap: () => act(ctx, () => client.killPane(id))),
        ]),
      ),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    // Height the keyboard takes from the terminal area (the Scaffold shrinks the body by the inset,
    // SafeArea gives back the nav-bar padding the keyboard covers). Phone mode sizes tmux WITHOUT it,
    // so showing the keyboard does not resize the pane; the view just scrolls.
    final kb = max(0.0, MediaQuery.viewInsetsOf(context).bottom - MediaQuery.viewPaddingOf(context).bottom);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          _topBar(),
          Expanded(child: _terminalArea(kb)),
          _extraKeys(),
        ]),
      ),
    );
  }

  double _barDx = 0;

  Widget _topBar() {
    final w = _window;
    final title = w == null ? _session : '$_session › ${w.index}:${w.name}${w.zoomed ? '  [Z]' : ''}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _sheet,
      // Distance OR velocity: a slow drag that stops before lifting has ~0 velocity.
      onHorizontalDragStart: (_) => _barDx = 0,
      onHorizontalDragUpdate: (d) => _barDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        final dx = v.abs() > 200 ? v : _barDx;
        if (dx.abs() > 200 || _barDx.abs() > 60) _stepWindow(dx < 0 ? 1 : -1);
      },
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: const Color(0xFF1E1E1E),
        child: Row(children: [
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
          MiniMap(
            panes: _rects,
            currentId: _paneId,
            onTapPane: (id) {
              _slideFrom = Offset.zero;
              _showPane(id, select: true);
            },
            onLongPress: _actions,
          ),
          IconButton(
            tooltip: 'Keyboard',
            icon: const Icon(Icons.keyboard),
            onPressed: () {
              final f = _panes[_paneId]?.focus;
              if (f == null) return;
              f.hasFocus ? f.unfocus() : f.requestFocus();
            },
          ),
        ]),
      ),
    );
  }

  Widget _terminalArea(double kb) => LayoutBuilder(builder: (context, c) {
        if (_phone) _fitClient(fitCells(Size(c.maxWidth, c.maxHeight + kb), _cell(_font)));
        final r = _termRect;
        final p = _panes[_paneId];
        if (r == null || p == null) return const Center(child: CircularProgressIndicator());
        final cwPerPt = _cell(100).width / 100;
        final font = _phone ? _font : c.maxWidth / (r.w * cwPerPt) * _zoom;
        final width = max(c.maxWidth, r.w * cwPerPt * font);
        final view = KeyedSubtree(
          key: ValueKey(r.id),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: width > c.maxWidth + 1 ? null : const NeverScrollableScrollPhysics(),
            child: SizedBox(
              width: width,
              height: c.maxHeight,
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                removeBottom: true,
                removeLeft: true,
                removeRight: true,
                child: TerminalView(
                  p.term,
                  focusNode: p.focus, // no autofocus: keyboard only on tap / keyboard button
                  autoResize: false,
                  deleteDetection: true,
                  textScaler: TextScaler.noScaling,
                  textStyle: TerminalStyle(fontSize: font),
                ),
              ),
            ),
          ),
        );
        return Listener(
          onPointerDown: _down,
          onPointerMove: _moveP,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _bump,
              builder: (context, child) => Transform.translate(
                offset: _bumpDir * 30 * sin(pi * _bump.value),
                child: child,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) {
                  final incoming = child.key == ValueKey(_paneId);
                  final tween = Tween(begin: incoming ? _slideFrom : -_slideFrom, end: Offset.zero);
                  return SlideTransition(position: tween.animate(anim), child: child);
                },
                child: view,
              ),
            ),
          ),
        );
      });

  Widget _extraKeys() {
    Widget btn(String label, VoidCallback onTap, {bool on = false}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            height: 40,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: on ? accent.withValues(alpha: 0.4) : null,
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
        );
    return Container(
      color: const Color(0xFF1E1E1E),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          btn('Esc', () => _key(TerminalKey.escape)),
          btn('Tab', () => _key(TerminalKey.tab)),
          btn('Ctrl', () => setState(() => _ctrl = !_ctrl), on: _ctrl),
          btn('Alt', () => setState(() => _alt = !_alt), on: _alt),
          btn('^C', () => _bytes(const [0x03])),
          btn('←', () => _key(TerminalKey.arrowLeft)),
          btn('↓', () => _key(TerminalKey.arrowDown)),
          btn('↑', () => _key(TerminalKey.arrowUp)),
          btn('→', () => _key(TerminalKey.arrowRight)),
          btn('Prefix', () => _bytes(const [0x02])),
          for (final s in const ['|', '~', '/', '-']) btn(s, () => _text(s)),
        ]),
      ),
    );
  }
}
