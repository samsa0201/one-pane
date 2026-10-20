import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ParagraphBuilder, ParagraphConstraints;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../tmux/control.dart';
import '../tmux/layout.dart';
import 'fonts.dart';
import 'gestures.dart';
import 'glass.dart';
import 'ime_input.dart';
import 'joystick.dart';
import 'term_filter.dart';
import 'minimap.dart';
import 'overview.dart';


/// Terminal text: the chosen Nerd Font (Hack bundled; icons in nvim, prompts), then symbol / CJK /
/// emoji fallbacks.
TerminalStyle _termStyle(double size) =>
    TerminalStyle(fontSize: size, fontFamily: termFont.value, fontFamilyFallback: const [
      'PocketSymbols2', // ⏵ ⏺ ✻ ✓ ☐ … (Claude Code's UI)
      'PocketSymbols', // ⎿ ⎯
      'Noto Sans Mono CJK SC',
      'Noto Color Emoji',
      'Noto Sans Symbols',
      'monospace',
      'sans-serif',
    ]);

/// One tmux pane mirrored into an xterm Terminal.
class _Pane {
  final Terminal term;
  final FocusNode focus = FocusNode();
  final ime = GlobalKey<ImeInputState>();
  final scroll = ScrollController(); // the live view's own scrollback
  late final ByteConversionSink decoder;
  int state = 0; // 0 capturing (drop output, capture has it), 1 awaiting cursor (buffer), 2 live
  final pending = <List<int>>[];
  int seeds = 0; // a newer _seed makes an older one stop
  (bool, bool, bool) modes = (false, false, false); // tmux's alternate_on, mouse_any, mouse_sgr
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

  /// Opens a fresh connection after a drop; null: a drop closes the screen.
  final Future<(SSHClient?, TmuxClient)> Function()? reconnect;

  /// Pane to open on (where the user was last time), if it still exists.
  final int? initialPane;

  /// Told the (session, pane) shown whenever it changes, to reopen there next time.
  final void Function(String session, int paneId)? onPlace;
  const PaneScreen(
      {super.key,
      this.ssh,
      required this.client,
      required this.session,
      this.reconnect,
      this.initialPane,
      this.onPlace});

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TmuxClient client = widget.client;
  late SSHClient? _ssh = widget.ssh;

  late String _session = widget.session;
  late int? _initialPane = widget.initialPane;
  (String, int)? _placed;
  List<WindowInfo> _windows = [];
  int? _winId, _paneId;
  bool _follow = true, _jumpToActive = false, _exited = false;
  final _panes = <int, _Pane>{};
  late StreamSubscription<TmuxEvent> _sub;
  Timer? _reloadTimer, _cmdTimer;
  Map<int, String> _commands = {}; // pane id → #{pane_current_command}, for the edge hints
  (int, Terminal)? _history; // read-only tmux scrollback overlay of that pane
  // One-finger vertical drag = scroll, decided by tmux's view of the pane: main screen → tmux history
  // view (opened by the drag, which keeps driving it, then flings); alternate screen → wheel / arrows.
  Offset? _scrollFrom; // where this one-finger gesture started; null: not (or no longer) a scroll candidate
  bool _scrolling = false;
  double _scrollDy = 0; // alt screen: px not yet sent as lines
  VelocityTracker? _vt;
  bool _histDrag = false; // this gesture opened the history view and drives it
  double _histPending = 0; // drag px that arrived before the history view was ready
  bool _histAway = false; // the history view was scrolled off its bottom (back at the bottom → live)
  final _histScroll = ScrollController();
  double _lineH = 16; // terminal line height in px, set by build
  int _gesturePtrs = 0; // max fingers down in this gesture
  bool _reconnecting = false;
  // Heartbeat: a no-op tmux command every 5 s; its round trip is the latency shown in the bar, no reply
  // in time = a dead connection (TCP can stay silent for minutes after a network change).
  Timer? _beatTimer;
  bool _beating = false;
  final _filters = Expando<TermFilter>();
  int? _rttMs;
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  Completer<void>? _kick; // completes to retry a reconnect right away (network back, app resumed)
  TmuxEvent? _lastEvent; // ignoring output; %sessions-changed right before %exit = session killed
  bool _hintsLit = true; // edge hints at full opacity (else dimmed)
  Timer? _hintTimer;

  // minimap scrub: a virtual pointer over the window layout drawn large
  int? _scrubFrom, _scrubAt; // pane shown when the scrub started / pane under the virtual pointer
  Offset _scrubPos = Offset.zero;

  // Phone mode (default): tmux sizes the window to our cols×rows at font [_font] and the shown pane is
  // kept zoomed. Desk mode: ignore-size, real pane size, font = fit-to-width × [_zoom] (≥ 1).
  static const _phonePref = 'phoneMode', _joystickPref = 'joystick', _stickPref = 'joystickPos';
  bool _joystick = true;
  Offset? _stick; // joystick centre as a fraction of the terminal area; null: bottom right
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
  bool _pinchQueued = false;
  double _startZoom = 1, _startFont = 13, _scale = 1;
  bool _pinching = false;

  WindowInfo? get _window => _windows.where((w) => w.id == _winId).firstOrNull;
  List<PaneRect> get _rects => _window?.panes ?? const [];
  PaneRect? get _rect => _rects.where((p) => p.id == _paneId).firstOrNull;

  /// The shown pane's real size (zoomed: the visible-layout rect).
  PaneRect? get _termRect => _paneId == null ? null : _window?.sizeOf(_paneId!);

  Size _cell(double font) => _cells[font] ??= terminalCellSize(_termStyle(font));

  /// New font, new cell size: phone mode re-fits tmux on the next build.
  void _fontChanged() => setState(_cells.clear);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    termFont.addListener(_fontChanged);
    _attach();
    _reload();
    // pane_current_command changes without a tmux notification
    _beatTimer = Timer.periodic(const Duration(seconds: 5), (_) => _beat());
    try {
      _netSub = Connectivity().onConnectivityChanged.listen((_) => _probe(), onError: (_) {});
    } catch (_) {} // no plugin (tests)
    _cmdTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final visible = ModalRoute.of(context)?.isCurrent ?? true;
      if (visible && !_reconnecting && !_exited && WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
        _loadCommands();
      }
    });
    () async {
      var phone = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        phone = prefs.getBool(_phonePref) ?? true;
        _joystick = prefs.getBool(_joystickPref) ?? true;
        if (prefs.getString(_stickPref)?.split(',').map(double.tryParse).toList() case [final x?, final y?]) {
          _stick = Offset(x, y);
        }
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
  Future<void> _unzoomOurs() async {
    final done = [for (final w in _zoomedByUs) client.unzoom(w).then((_) {}, onError: (_) {})];
    _zoomedByUs.clear();
    await Future.wait(done);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    termFont.removeListener(_fontChanged);
    _histScroll.dispose();
    _sub.cancel();
    _reloadTimer?.cancel();
    _cmdTimer?.cancel();
    _beatTimer?.cancel();
    _netSub?.cancel();
    _sizeTimer?.cancel();
    _hintTimer?.cancel();
    _bump.dispose();
    for (final p in _panes.values) {
      p.focus.dispose();
      p.scroll.dispose();
    }
    // Closing SSH right after writing the unzoom commands dropped them; wait for tmux's replies first.
    final unzoomed = _exited ? Future<void>.value() : _unzoomOurs().timeout(const Duration(seconds: 2), onTimeout: () {});
    _exited = true;
    final (c, ssh) = (client, _ssh);
    unzoomed.whenComplete(() {
      c.close().catchError((_) {});
      ssh?.close();
    });
    super.dispose();
  }

  // ---------- connection ----------

  /// Listens to the current client / ssh; callbacks from replaced ones are ignored.
  void _attach() {
    final c = client, ssh = _ssh;
    _sub = c.events.listen(_onEvent);
    c.done.then((_) {
      if (c == client) _lost('Connection lost');
    });
    ssh?.done.whenComplete(() {
      if (ssh == _ssh) _lost('Connection closed');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _probe(); // the socket may have died in the background
  }

  /// Network changed or app back: check now with a short timeout (over Tailscale the connection often
  /// survives a wifi ↔ mobile switch), or retry at once if already reconnecting.
  void _probe() {
    if (_exited) return;
    if (_reconnecting) {
      if (!(_kick?.isCompleted ?? true)) _kick!.complete();
      return;
    }
    _beat(timeout: const Duration(seconds: 3));
  }

  Future<void> _beat({Duration timeout = const Duration(seconds: 8)}) async {
    if (_beating || _reconnecting || _exited) return;
    if (WidgetsBinding.instance.lifecycleState case AppLifecycleState.paused || AppLifecycleState.hidden) return;
    _beating = true;
    final c = client, sw = Stopwatch()..start();
    try {
      await c.cmd('display -p ok').timeout(timeout);
      if (mounted && c == client) setState(() => _rttMs = sw.elapsedMilliseconds);
    } catch (_) {
      if (c == client) _lost('No reply from the server');
    } finally {
      _beating = false;
    }
  }

  /// Connection dropped (not by us): reconnect if we can, else leave.
  void _lost(String msg) {
    if (_exited || !mounted || _reconnecting) return;
    if (widget.reconnect == null) return _exit(msg);
    _reconnectLoop();
  }

  /// Retries at once, then after 1, 2, 4, 8, 15, 15... s (or right away when the network comes back /
  /// the app resumes) for about 5 minutes.
  Future<void> _reconnectLoop() async {
    setState(() {
      _reconnecting = true;
      _rttMs = null;
    });
    _sub.cancel();
    client.close().catchError((_) {});
    _ssh?.close();
    final until = DateTime.now().add(const Duration(minutes: 5));
    var delay = 0;
    Object? error;
    while (DateTime.now().isBefore(until)) {
      final kick = _kick = Completer<void>();
      await Future.any([Future<void>.delayed(Duration(seconds: delay)), kick.future]);
      delay = delay == 0 ? 1 : min(delay * 2, 15);
      if (!mounted || _exited) return;
      try {
        final (ssh, c) = await widget.reconnect!();
        if (!mounted || _exited) {
          c.close().catchError((_) {});
          ssh?.close();
          return;
        }
        client = c;
        _ssh = ssh;
        _attach();
        await _restore();
        if (mounted) setState(() => _reconnecting = false);
        _beat();
        return;
      } catch (e) {
        error = e;
      }
    }
    _reconnecting = false;
    _exit('Reconnect failed: $error');
  }

  /// After a reconnect: same window/pane if they still exist, panes reseeded, size/zoom re-sent.
  Future<void> _restore() async {
    for (final p in _panes.values) {
      p.state = 0; // drop output until reseeded
    }
    final old = _panes.keys.toSet();
    await _reload(keepIds: true); // creates (and seeds) new panes, drops dead ones
    for (final e in _panes.entries) {
      if (old.contains(e.key)) _seed(e.key, e.value, reset: true);
    }
    if (_phoneMode == false) {
      _run(client.ignoreSize(true));
    } else {
      setState(() => _sentSize = _wantSize = null); // next build re-sends -C
      _keepZoomed();
    }
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
        final r = e.reason ?? '';
        // tmux 3.6 sends a bare %exit both for a detach and a killed session; a kill is announced by
        // %sessions-changed just before.
        if (_lastEvent is SessionsChangedEvent || RegExp('session|server exited').hasMatch(r)) {
          _exit(r.isEmpty ? 'Session ended' : r);
        } else {
          _lost(r.isEmpty ? 'tmux exited' : r);
        }
      case SessionsChangedEvent():
        break;
    }
    if (e is! OutputEvent) _lastEvent = e;
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

  Future<void> _reload({bool keepIds = false}) async {
    final List<WindowInfo> windows;
    try {
      windows = await client.listWindows();
    } catch (e) {
      return; // connection errors surface through ExitEvent / done
    }
    if (!mounted || windows.isEmpty) return;
    _loadCommands();
    final before = (_winId, _paneId);
    final resized = <MapEntry<int, _Pane>>[];
    final want = _initialPane; // first load only: where the user was
    _initialPane = null;
    final wantWin = want == null ? null : windows.where((w) => w.panes.any((p) => p.id == want)).firstOrNull;
    setState(() {
      _windows = windows;
      final active = windows.where((w) => w.active).firstOrNull ?? windows.first;
      final oldWin = _winId;
      if (_winId == null || _window == null || (_follow && !keepIds) || _jumpToActive) _winId = active.id;
      _jumpToActive = false;
      if (wantWin != null) _winId = wantWin.id;
      final win = _window!;
      if (_winId != oldWin || _rect == null) _paneId = win.activePane;
      if (wantWin != null) _paneId = want;

      final alive = {for (final w in windows) for (final p in w.panes) p.id: p};
      _panes.removeWhere((id, p) {
        if (alive.containsKey(id)) return false;
        p.focus.dispose();
        p.scroll.dispose();
        return true;
      });
      for (final w in windows) {
        for (final r in w.visiblePanes) {
          alive[r.id] = r; // zoomed pane: real size
        }
      }
      for (final e in _panes.entries) {
        final r = alive[e.key]!;
        if (e.value.term.viewWidth != r.w || e.value.term.viewHeight != r.h) {
          e.value.term.resize(r.w, r.h);
          // tmux reflows its copy without sending output; xterm's own reflow differs (duplicated or
          // stale lines after a zoom / keyboard / font change), so take tmux's screen again.
          resized.add(e);
        }
      }
      for (final p in win.panes) {
        _ensurePane(win.sizeOf(p.id)!);
      }
    });
    for (final e in resized) {
      _seed(e.key, e.value, reset: true);
    }
    if (wantWin != null) {
      _run(client.selectWindow(wantWin.id));
      _run(client.selectPane(want!, keepZoom: _phone));
    }
    _refreshModes();
    _remember();
    if ((_winId, _paneId) != before) {
      _keepZoomed();
      _wakeHints();
    }
  }

  Future<void> _loadCommands() async {
    _refreshModes();
    try {
      final c = await client.paneCommands();
      if (mounted) setState(() => _commands = c);
    } catch (_) {}
  }

  /// The shown pane's screen/mouse modes from tmux, so a scroll knows what it means before it starts.
  void _refreshModes() {
    final p = _panes[_paneId], id = _paneId;
    if (p == null || id == null) return;
    client.paneModes(id).then((m) {
      p.modes = m;
    }, onError: (_) {});
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
    _seed(r.id, p);
  }

  /// capture-pane + cursor into the pane's terminal, then live output. [reset]: clear it first
  /// (home + erase: xterm.dart ignores RIS `ESC c`).
  Future<void> _seed(int id, _Pane p, {bool reset = false}) async {
    final seq = ++p.seeds;
    p.state = 0;
    p.pending.clear();
    try {
      final screen = await client.capturePane(id);
      if (seq != p.seeds) return;
      p.state = 1;
      final (x, y) = await client.cursor(id);
      if (seq != p.seeds) return;
      if (reset) _filters[p.term]?.reset();
      // Pen back to default after the capture (its last cell's colour stuck otherwise): apps that
      // write single characters without SGR (Claude Code's input line) assume the default.
      _writer(p.term)('${reset ? '\x1b[0m\x1b[H\x1b[2J' : ''}$screen\x1b[0m\x1b[${y + 1};${x + 1}H');
    } catch (_) {
      if (seq != p.seeds) return;
      // pane may have vanished; go live anyway
    }
    p.state = 2;
    for (final b in p.pending) {
      p.decoder.add(b);
    }
    p.pending.clear();
  }

  /// Writes to a terminal; replies the terminal emulator generates while parsing
  /// (DA, DSR...) are dropped: tmux already answered the program.
  /// Output goes through a [TermFilter] per terminal (sequences xterm.dart misreads).
  void Function(String) _writer(Terminal t) => (s) {
        _writing = true;
        try {
          t.write((_filters[t] ??= TermFilter()).add(s));
        } finally {
          _writing = false;
        }
      };

  // ---------- input ----------

  void _onInput(int paneId, String data) {
    if (_writing) return;
    _closeHistory();
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

  /// Clipboard text into the pane, newlines as Enter; bracketed if the program enabled it (xterm decides).
  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final t = _panes[_paneId]?.term;
    if (text == null || text.isEmpty || t == null) return;
    // an embedded end marker would let the pasted rest run as typed input
    t.paste(text.replaceAll('\x1b[201~', '').replaceAll('\r\n', '\r').replaceAll('\n', '\r'));
  }

  void _bytes(List<int> b) {
    _closeHistory();
    if (_paneId != null) _run(client.sendBytes(_paneId!, b));
  }

  // then/onError, not catchError: helpers typed Future<void> are Future<List<String>> at runtime.
  void _run(Future<void> f) => f.then((_) {}, onError: (Object e) {
        if (mounted && !_reconnecting) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      });

  // ---------- one-finger scroll ----------

  void _scrollDown(PointerDownEvent e) {
    _scrollFrom = _history != null && !_histDrag ? null : e.position; // an open history view scrolls itself
    _scrolling = false;
    _scrollDy = 0;
    _vt = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position);
    _refreshModes(); // usually back before the slop is passed
  }

  void _scrollMove(PointerMoveEvent e) {
    final from = _scrollFrom, p = _panes[_paneId], id = _paneId;
    if (from == null || p == null || id == null) return;
    _vt?.addPosition(e.timeStamp, e.position);
    var dy = e.delta.dy;
    if (!_scrolling) {
      final d = e.position - from;
      if (d.distance < 12) return;
      if (d.dx.abs() > d.dy.abs()) {
        _scrollFrom = null; // sideways: not a scroll
        return;
      }
      _scrolling = true;
      dy = d.dy; // the slop counts
    }
    final (alt, mouse, sgr) = p.modes;
    if (alt && _histDrag) {
      _histDrag = false; // the modes came back late: it is a full-screen app after all
      _closeHistory();
    }
    if (!alt) {
      if (_history == null) {
        if (dy <= 0) return; // already at the live bottom
        _histDrag = true;
        _histPending = 0;
        _openHistory();
      }
      _dragHistory(dy);
      return;
    }
    // Alternate screen (vim, less, htop, TUIs): whole lines as mouse wheel if the app asked for the
    // mouse, else arrow keys. Finger down = earlier content = wheel up.
    _scrollDy += dy;
    final lines = _scrollDy ~/ _lineH;
    if (lines == 0) return;
    _scrollDy -= lines * _lineH;
    final up = lines > 0;
    final r = _termRect;
    final col = (r?.w ?? 2) ~/ 2 + 1, row = (r?.h ?? 2) ~/ 2 + 1;
    for (var i = 0; i < lines.abs(); i++) {
      if (mouse) {
        final b = up ? 64 : 65;
        _run(client.sendBytes(
            id,
            sgr
                ? utf8.encode('\x1b[<$b;$col;${row}M')
                : [0x1b, 0x5b, 0x4d, 32 + b, min(255, 32 + col), min(255, 32 + row)]));
      } else {
        p.term.keyInput(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
      }
    }
  }

  void _scrollEnd() {
    if (_histDrag) {
      _histDrag = false;
      final v = _vt?.getVelocity().pixelsPerSecond.dy ?? 0;
      final pos = _histScroll.hasClients ? _histScroll.position : null;
      if (pos is ScrollPositionWithSingleContext) pos.goBallistic(-v); // native fling from our drag
    }
    _scrollFrom = null;
    _scrolling = false;
    _vt = null;
  }

  void _dragHistory(double dy) {
    if (!_histScroll.hasClients) {
      _histPending += dy; // still capturing
      return;
    }
    final pos = _histScroll.position;
    if (!pos.hasContentDimensions) return;
    _histScroll.jumpTo((pos.pixels - dy).clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  // ---------- tmux scrollback ----------

  /// The live view only has what arrived since attach; older lines come from tmux's history.
  Future<void> _openHistory() async {
    final id = _paneId, r = _termRect;
    if (id == null || r == null || _history?.$1 == id) return;
    final String text;
    try {
      text = await client.captureHistory(id);
    } catch (_) {
      return;
    }
    if (!mounted || id != _paneId) return;
    final t = Terminal(maxLines: 5000)..resize(r.w, r.h);
    t.write(TermFilter().add(text));
    _histAway = false;
    setState(() => _history = (id, t));
    // first frame lays out the view at its bottom; then the drag so far
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final dy = _histPending;
      _histPending = 0;
      if (dy != 0) _dragHistory(dy);
    });
  }

  void _closeHistory() {
    if (_history != null) setState(() => _history = null);
  }

  bool get _keyboardUp => MediaQuery.viewInsetsOf(context).bottom > 0;

  void _showKeyboard(_Pane? p) {
    p?.focus.requestFocus();
    p?.ime.currentState?.show();
  }

  // ---------- navigation ----------

  void _showPane(int id, {bool select = false}) {
    if (!mounted) return;
    final hadKeyboard = _keyboardUp; // focus alone outlives a keyboard hidden with back
    setState(() {
      _history = null;
      _paneId = id;
      final r = _termRect;
      if (r != null) _ensurePane(r);
    });
    if (hadKeyboard) WidgetsBinding.instance.addPostFrameCallback((_) => _showKeyboard(_panes[id]));
    if (select) _run(client.selectPane(id, keepZoom: _phone));
    _keepZoomed();
    _wakeHints();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshModes());
    _remember();
  }

  void _remember() {
    final id = _paneId;
    if (id == null || _placed == (_session, id)) return;
    _placed = (_session, id);
    widget.onPlace?.call(_session, id);
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
      _history = null;
      _slideFrom = slideFrom;
      _winId = id;
      _paneId = w.activePane;
      for (final p in w.panes) {
        _ensurePane(w.sizeOf(p.id)!);
      }
    });
    _run(client.selectWindow(id));
    _keepZoomed();
    _wakeHints();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshModes());
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

  /// Next / previous session (tmux's list order); bump at the ends.
  Future<void> _stepSession(int delta) async {
    final List<SessionInfo> ss;
    try {
      ss = await client.listSessions();
    } catch (_) {
      return;
    }
    final i = ss.indexWhere((s) => s.name == _session);
    final j = i + delta;
    if (!mounted) return;
    if (i < 0 || j < 0 || j >= ss.length) {
      _bumpDir = Offset(0, delta.toDouble());
      _bump.forward(from: 0);
      HapticFeedback.lightImpact();
      return;
    }
    _slideFrom = Offset(0, delta.toDouble());
    _run(client.switchSession(ss[j].name));
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

  /// Edge hints at full opacity for 2 s, then dimmed: the top one covers the first terminal row.
  void _wakeHints() {
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hintsLit = false);
    });
    if (!_hintsLit) setState(() => _hintsLit = true);
  }

  // ---------- minimap scrub ----------

  /// The scrub overlay's layout size: the window's aspect, fit into most of the screen.
  Size get _scrubSize {
    final s = MediaQuery.sizeOf(context);
    final r = scaleRects(_rects, Size(s.width - 48, s.height / 2)).values;
    return Size(r.map((e) => e.right).fold(0.0, max), r.map((e) => e.bottom).fold(0.0, max));
  }

  void _scrubStart(DragStartDetails _) {
    final id = _paneId;
    final r = id == null ? null : scaleRects(_rects, _scrubSize)[id];
    if (r == null) return;
    setState(() {
      _scrubFrom = _scrubAt = id;
      _scrubPos = r.center;
    });
  }

  /// Finger movement ×3 moves the virtual pointer, so a thumb's reach covers the map.
  void _scrubUpdate(DragUpdateDetails d) {
    if (_scrubFrom == null) return;
    final size = _scrubSize, p = _scrubPos + d.delta * 3;
    _scrubPos = Offset(p.dx.clamp(0, size.width - 0.5), p.dy.clamp(0, size.height - 0.5));
    final id = paneAt(_rects, size, _scrubPos);
    if (id != null && id != _scrubAt) {
      HapticFeedback.selectionClick();
      setState(() => _scrubAt = id);
    }
  }

  void _scrubEnd(DragEndDetails _) {
    final from = _scrubFrom, to = _scrubAt;
    _scrubCancel();
    if (to == null || to == from || !_rects.any((p) => p.id == to)) return;
    _slideFrom = Offset.zero;
    _showPane(to, select: true);
  }

  void _scrubCancel() {
    if (_scrubFrom != null) setState(() => _scrubFrom = _scrubAt = null);
  }

  Widget _scrubOverlay() {
    final size = _scrubSize;
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: SizedBox.fromSize(
            size: size,
            child: Stack(children: [
              CustomPaint(size: size, painter: MiniMapPainter(_rects, _scrubAt)),
              for (final e in scaleRects(_rects, size).entries)
                Positioned.fromRect(
                  rect: e.value,
                  child: Center(
                    child: Text(
                      _commands[e.key] ?? '%${e.key}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: e.key == _scrubAt ? Colors.black : Colors.white),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- two-finger gestures ----------

  Offset _focal(Map<int, Offset> m) => m.values.reduce((a, b) => a + b) / m.length.toDouble();
  double _spread(Map<int, Offset> m) {
    final v = m.values.toList();
    return max((v[0] - v[1]).distance, 1);
  }

  void _down(PointerDownEvent e) {
    _wakeHints();
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length == 1) _scrollDown(e);
    _gesturePtrs = max(_gesturePtrs, _ptrs.length);
    if (_ptrs.length > 1) _scrollFrom = null;
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
    if (_gesturePtrs == 1) _scrollMove(e);
    final s = _start;
    if (s == null || _ptrs.length != 2 || !s.keys.every(_ptrs.containsKey)) return;
    // Once per pointer packet: between finger 0's and finger 1's move of one packet the spread looks
    // changed, and a fast parallel swipe was taken for a pinch.
    if (_pinchQueued) return;
    _pinchQueued = true;
    scheduleMicrotask(() {
      _pinchQueued = false;
      final s = _start;
      if (!mounted || s == null || _ptrs.length != 2 || !s.keys.every(_ptrs.containsKey)) return;
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
        if (_lastTwoTap != null && now.difference(_lastTwoTap!).inMilliseconds < 500) {
          _lastTwoTap = null;
          if (_paneId != null) _run(client.toggleZoom(_paneId!));
        } else {
          _lastTwoTap = now;
        }
      }
    }
    _ptrs.remove(e.pointer);
    if (_ptrs.isEmpty) {
      if (_gesturePtrs == 1) _scrollEnd();
      _gesturePtrs = 0;
    }
  }

  // ---------- sheets ----------

  void _sheet() {
    showGlassSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: FutureBuilder<List<SessionInfo>>(
            future: client.listSessions(),
            builder: (ctx, snap) => ListView(shrinkWrap: true, children: [
              const _Header('Sessions'),
              // Each session opens to its windows; the current one starts open.
              for (final s in snap.data ?? const <SessionInfo>[])
                ExpansionTile(
                  key: PageStorageKey('session ${s.name}'),
                  initiallyExpanded: s.name == _session,
                  leading: Icon(Icons.dns, color: s.name == _session ? accent : null),
                  title: Text(s.name, style: TextStyle(color: s.name == _session ? accent : null)),
                  subtitle: Text('${s.windows} windows${s.attached ? ' · attached' : ''}'),
                  childrenPadding: const EdgeInsets.only(left: 16),
                  children: s.name == _session
                      ? [
                          for (final w in _windows)
                            ListTile(
                              leading: const Icon(Icons.web_asset),
                              title: Text('${w.index}:${w.name}'),
                              subtitle: Text('${w.panes.length} panes${w.zoomed ? ' · zoomed' : ''}'),
                              selected: w.id == _winId,
                              trailing: SizedBox(
                                  width: 40,
                                  height: 26,
                                  child: MiniMap(panes: w.panes, currentId: w.activePane, size: const Size(40, 26))),
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
                        ]
                      : [
                          FutureBuilder<List<(int, String, int)>>(
                            future: client.listWindowsOf(s.name),
                            builder: (ctx, ws) => Column(children: [
                              if (!ws.hasData) const LinearProgressIndicator(minHeight: 1),
                              for (final (idx, name, panes) in ws.data ?? const <(int, String, int)>[])
                                ListTile(
                                  leading: const Icon(Icons.web_asset),
                                  title: Text('$idx:$name'),
                                  subtitle: Text('$panes panes'),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _run(client.switchTo(s.name, idx));
                                  },
                                ),
                            ]),
                          ),
                        ],
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
              SwitchListTile(
                title: const Text('Joystick'),
                subtitle: const Text('Floating stick: push toward a pane and let go to move there; tap for the '
                    'overview'),
                value: _joystick,
                onChanged: (v) {
                  setState(() => _joystick = v);
                  setSheet(() {});
                  SharedPreferences.getInstance().then((p) => p.setBool(_joystickPref, v)).catchError((_) => true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.font_download_outlined),
                title: const Text('Terminal font'),
                subtitle: Text(termFonts.firstWhere((f) => f.family == termFont.value).name),
                onTap: () {
                  Navigator.pop(ctx);
                  _fontPicker();
                },
              ),
              SwitchListTile(
                title: const Text('Glass effects'),
                subtitle: const Text('Frosted, see-through panels. Off: plain panels, lighter on the GPU'),
                value: glassEffects.value,
                onChanged: (v) {
                  setGlassEffects(v);
                  setSheet(() {});
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Nerd Fonts: Hack is bundled, the others download once (about 2–5 MB each) when picked.
  void _fontPicker() {
    String? busy;
    double progress = 0;
    showGlassSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const _Header('Terminal font'),
            for (final f in termFonts)
              FutureBuilder<bool>(
                future: fontReady(f),
                builder: (ctx, ready) => ListTile(
                  title: Text(f.name, style: ready.data == true ? TextStyle(fontFamily: f.family) : null),
                  subtitle: Text(f.bundled ? 'built in' : (ready.data == true ? 'downloaded' : 'tap to download')),
                  selected: f.family == termFont.value,
                  trailing: busy == f.family
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(value: progress > 0 ? progress : null, strokeWidth: 2))
                      : f.family == termFont.value
                          ? const Icon(Icons.check)
                          : ready.data == false
                              ? const Icon(Icons.download_outlined)
                              : null,
                  onTap: busy != null
                      ? null
                      : () async {
                          setSheet(() {
                            busy = f.family;
                            progress = 0;
                          });
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await useFont(f, onProgress: (p) {
                              if (ctx.mounted) setSheet(() => progress = p);
                            });
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('${f.name}: $e')));
                          }
                          if (ctx.mounted) setSheet(() => busy = null);
                        },
                ),
              ),
          ]),
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

    showGlassSheet<void>(
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
    return Scaffold(
      body: SafeArea(
        child: Stack(fit: StackFit.expand, children: [
          Column(children: [
            // Window bar + keys: one glass dock at the bottom, next to the thumb.
            Expanded(child: _terminalArea()),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Glass(
                radius: const BorderRadius.all(Radius.circular(26)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [_topBar(), _extraKeys()]),
              ),
            ),
          ]),
          if (_scrubFrom != null) _scrubOverlay(),
        ]),
      ),
    );
  }

  double _barDx = 0;

  Widget _topBar() {
    final w = _window;
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
        height: 52,
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(children: [
          Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                      TextSpan(text: _session, children: [
                        if (_rttMs case final ms?)
                          TextSpan(
                              text: '  ${ms}ms',
                              style: TextStyle(
                                  color: ms < 150
                                      ? Colors.greenAccent.withValues(alpha: 0.7)
                                      : ms < 400
                                          ? Colors.amberAccent
                                          : Colors.redAccent)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white54, letterSpacing: 0.3)),
                  Row(children: [
                    Flexible(
                      child: Text(w == null ? '…' : '${w.index}:${w.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    if (w != null && _windows.length > 1)
                      Text('  ${_windows.indexOf(w) + 1}/${_windows.length}',
                          style: const TextStyle(fontSize: 11, color: Colors.white38)),
                    if (w?.zoomed ?? false)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          border: Border.all(color: accent.withValues(alpha: 0.7)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('Z', style: TextStyle(fontSize: 10, color: accent)),
                      ),
                  ]),
                ]),
          ),
          const SizedBox(width: 8),
          MiniMap(
            panes: _rects,
            currentId: _paneId,
            size: const Size(40, 44), // phone-shaped
            onTapPane: (id) {
              _slideFrom = Offset.zero;
              _showPane(id, select: true);
            },
            onLongPress: _actions,
            onPanStart: _scrubStart,
            onPanUpdate: _scrubUpdate,
            onPanEnd: _scrubEnd,
            onPanCancel: _scrubCancel,
          ),
          IconButton(
            tooltip: 'Overview',
            icon: const Icon(Icons.grid_view, size: 22),
            visualDensity: VisualDensity.compact,
            onPressed: _openOverview,
          ),
          IconButton(
            tooltip: 'Keyboard',
            icon: const Icon(Icons.keyboard, size: 22),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final p = _panes[_paneId];
              _keyboardUp ? p?.focus.unfocus() : _showKeyboard(p);
            },
          ),
        ]),
      ),
    );
  }

  // Phone mode sizes tmux to what is visible, keyboard included: with a taller pane under the keyboard
  // the view sat at the pane's bottom while the prompt was at its top (blank screen while typing).
  Widget _terminalArea() => LayoutBuilder(builder: (context, c) {
        if (_phone) _fitClient(fitCells(Size(c.maxWidth, c.maxHeight), _cell(_font)));
        final r = _termRect;
        final p = _panes[_paneId];
        if (r == null || p == null) return const Center(child: CircularProgressIndicator());
        final cwPerPt = _cell(100).width / 100;
        final font = _phone ? _font : c.maxWidth / (r.w * cwPerPt) * _zoom;
        final width = max(c.maxWidth, r.w * cwPerPt * font);
        _lineH = _cell(font).height;
        final termH = max(c.maxHeight, r.h * _lineH);
        final view = KeyedSubtree(
          key: ValueKey(r.id),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: width > c.maxWidth + 1 ? null : const NeverScrollableScrollPhysics(),
            child: SizedBox(
              width: width,
              height: c.maxHeight,
              // Never shorter than the pane, top-aligned: while the keyboard slides up and before tmux has
              // shrunk the pane, the bottom rows hide behind it instead of xterm pushing the screen up.
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minHeight: termH,
                maxHeight: termH,
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  removeLeft: true,
                  removeRight: true,
                  // Soft keyboard through ImeInput (Vietnamese IMEs); TerminalView only takes hardware keys.
                  child: ImeInput(
                    key: p.ime,
                    focusNode: p.focus,
                    onInsert: p.term.textInput,
                    onBackspace: () => p.term.keyInput(TerminalKey.backspace),
                    onEnter: () => p.term.keyInput(TerminalKey.enter),
                    // Pointer-transparent: scrolls, taps and gestures are ours (tmux decides what a scroll
                    // means); the view keeps its focus node for hardware keys.
                    child: IgnorePointer(
                      child: TerminalView(
                        p.term,
                        focusNode: p.focus, // no autofocus: keyboard only on tap / keyboard button
                        scrollController: p.scroll,
                        autoResize: false,
                        hardwareKeyboardOnly: true,
                        textScaler: TextScaler.noScaling,
                        textStyle: _termStyle(font),
                        theme: terminalTheme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final h = _history;
        final area = Listener(
          onPointerDown: _down,
          onPointerMove: _moveP,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(fit: StackFit.expand, children: [
            ClipRect(
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
            if (h != null && h.$1 == r.id) _historyView(h.$2, font),
            ..._edgeHints(),
            if (_reconnecting)
              const Align(
                alignment: Alignment.topCenter,
                child: IgnorePointer(child: _Pill('Reconnecting…', progress: true)),
              ),
          ]),
        );
        if (!_joystick || h != null) return area; // history: the LIVE chip sits there
        // Outside the Listener: its drags must not count as terminal gestures (pull to history, pinch).
        final id = _paneId;
        const half = 36.0; // joystick radius
        final area0 = Size(c.maxWidth, c.maxHeight);
        Offset clampIn(Offset p) => Offset(p.dx.clamp(half, max(half, area0.width - half)),
            p.dy.clamp(half, max(half, area0.height - half)));
        Offset stickCenter() {
          final st = _stick;
          return clampIn(st == null
              ? Offset(area0.width - 12 - half, area0.height - 12 - half)
              : Offset(st.dx * area0.width, st.dy * area0.height));
        }

        final center = stickCenter();
        return Stack(fit: StackFit.expand, children: [
          area,
          Positioned(
            left: center.dx - half,
            top: center.dy - half,
            child: Joystick(
              available: {for (final d in Dir.values) if (id != null && neighbor(_rects, id, d) != null) d},
              onMove: _move,
              onWindow: _stepWindow,
              onSession: _stepSession,
              onTap: _openOverview,
              // From the current position, not this build's: several moves can arrive between frames.
              onDragBy: (d) => setState(() {
                final p = clampIn(stickCenter() + d);
                _stick = Offset(p.dx / area0.width, p.dy / area0.height);
              }),
              onDragEnd: () {
                final st = _stick;
                if (st == null) return;
                SharedPreferences.getInstance()
                    .then((p) => p.setString(_stickPref, '${st.dx},${st.dy}'))
                    .catchError((_) => true);
              },
            ),
          ),
        ]);
      });

  /// Read-only tmux history over the live view, starting at the bottom (xterm sticks to the bottom).
  Widget _historyView(Terminal t, double font) => Stack(children: [
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0xF20A0C11),
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              removeBottom: true,
              // Scrolled back down to the bottom by the user → live again.
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.extentAfter > _lineH) _histAway = true;
                  if (n is ScrollEndNotification && _histAway && !_histDrag && n.metrics.extentAfter < 1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _closeHistory());
                  }
                  return false;
                },
                child: Scrollbar(
                  controller: _histScroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 6,
                  child: TerminalView(
                    t,
                    readOnly: true,
                    hardwareKeyboardOnly: true,
                    autoResize: false,
                    scrollController: _histScroll,
                    textScaler: TextScaler.noScaling,
                    textStyle: _termStyle(font),
                    theme: terminalTheme,
                  ),
                ),
              ),
            ),
          ),
        ),
        // How far back: lines above the live bottom (top right: the up-neighbour hint is top centre).
        Align(
          alignment: Alignment.topRight,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: _histScroll,
              builder: (context, _) {
                final pos = _histScroll.hasClients ? _histScroll.position : null;
                final back = pos != null && pos.hasContentDimensions ? (pos.extentAfter / _lineH).round() : 0;
                return _Pill('History · ↑ $back lines');
              },
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: ActionChip(
            avatar: const Icon(Icons.arrow_downward, size: 16),
            label: const Text('LIVE'),
            onPressed: _closeHistory,
          ),
        ),
      ]);

  /// Pills on the edges that have a spatial neighbour, with its current command.
  List<Widget> _edgeHints() {
    final id = _paneId;
    if (id == null) return const [];
    return [
      for (final (d, align) in const [
        (Dir.left, Alignment.centerLeft),
        (Dir.right, Alignment.centerRight),
        (Dir.up, Alignment.topCenter),
        (Dir.down, Alignment.bottomCenter),
      ])
        if (neighbor(_rects, id, d) case final n?)
          Align(
            alignment: align,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hintsLit ? 1 : 0.15,
                duration: const Duration(milliseconds: 400),
                child: _Pill(switch (d) {
                  Dir.left => '‹ ${_commands[n] ?? '%$n'}',
                  Dir.right => '${_commands[n] ?? '%$n'} ›',
                  Dir.up => '˄ ${_commands[n] ?? '%$n'}',
                  Dir.down => '˅ ${_commands[n] ?? '%$n'}',
                }),
              ),
            ),
          ),
    ];
  }

  Widget _extraKeys() {
    // Key caps; sticky Ctrl/Alt are filled with the accent while armed.
    Widget btn(String label, VoidCallback onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Material(
            color: on ? accent : Colors.white.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: const BoxConstraints(minWidth: 42),
                height: 38,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 15,
                        color: on ? Colors.black : Colors.white,
                        fontWeight: on ? FontWeight.w600 : FontWeight.normal)),
              ),
            ),
          ),
        );
    const gap = SizedBox(width: 8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          btn('Esc', () => _key(TerminalKey.escape)),
          btn('Tab', () => _key(TerminalKey.tab)),
          btn('Ctrl', () => setState(() => _ctrl = !_ctrl), on: _ctrl),
          btn('Alt', () => setState(() => _alt = !_alt), on: _alt),
          btn('^C', () => _bytes(const [0x03])),
          gap,
          btn('←', () => _key(TerminalKey.arrowLeft)),
          btn('↓', () => _key(TerminalKey.arrowDown)),
          btn('↑', () => _key(TerminalKey.arrowUp)),
          btn('→', () => _key(TerminalKey.arrowRight)),
          gap,
          btn('Prefix', () => _bytes(const [0x02])),
          btn('Paste', _paste),
          gap,
          for (final s in const ['|', '~', '/', '-']) btn(s, () => _text(s)),
        ]),
      ),
    );
  }
}

/// Section label in the bottom sheets.
class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: accent, fontWeight: FontWeight.w600)),
      );
}

/// Slim translucent label over the terminal.
class _Pill extends StatelessWidget {
  final String text;
  final bool progress;
  const _Pill(this.text, {this.progress = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(6),
        child: Glass(
          radius: const BorderRadius.all(Radius.circular(14)),
          blur: 12,
          strength: 0.8,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (progress) ...[
              const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
              const SizedBox(width: 6),
            ],
            Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
          ]),
        ),
      );
}
