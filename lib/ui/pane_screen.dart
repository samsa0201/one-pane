import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ParagraphBuilder, ParagraphConstraints;

import 'package:clock/clock.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../ssh/connection.dart' show HostKeyError;
import '../tmux/control.dart';
import '../tmux/layout.dart';
import 'fonts.dart';
import 'gestures.dart';
import 'glass.dart';
import 'ime_input.dart';
import 'joystick.dart';
import 'keys.dart';
import 'term_filter.dart';
import 'minimap.dart';
import 'overview.dart';
import 'parts.dart';
import 'settings_screen.dart';


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

  /// Host name, for the switcher and the connection-lost card.
  final String title;
  const PaneScreen(
      {super.key,
      this.title = 'server',
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
  bool _jumpToActive = false, _exited = false;
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
  int _tries = 0; // reconnect attempts so far
  String? _why; // what dropped the connection
  String? _lostError; // reconnecting gave up: the card offers retry
  bool _lostKey = false; // ...because the server's key was refused
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
  static const _stickPref = 'joystickPos';
  Offset? _stick; // joystick centre as a fraction of the terminal area; null: bottom right
  bool? _phoneMode; // null until the pref is loaded: render as phone, send nothing yet
  bool get _phone => _phoneMode ?? true;
  double _font = termFontSize.value;
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
    phoneMode.addListener(_phoneChanged);
    joystickOn.addListener(_settingsChanged);
    termPalette.addListener(_paletteChanged);
    keyPages.addListener(_settingsChanged);
    termFontSize.addListener(_fontSizeChanged);
    _setPhone(phoneMode.value);
    SharedPreferences.getInstance().then((prefs) {
      if (prefs.getString(_stickPref)?.split(',').map(double.tryParse).toList() case [final x?, final y?]) {
        if (mounted) setState(() => _stick = Offset(x, y));
      }
    }).catchError((_) {});
  }

  void _settingsChanged() {
    if (mounted) setState(() {});
  }

  void _paletteChanged() {
    _colorsSent.clear();
    _reportColors();
    _settingsChanged();
  }

  void _phoneChanged() => _setPhone(phoneMode.value);

  void _fontSizeChanged() {
    if (mounted && _font != termFontSize.value) setState(() => _font = termFontSize.value);
  }

  void _setPhone(bool on) {
    final was = _phoneMode;
    if (was == on) return;
    setState(() => _phoneMode = on);
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
    phoneMode.removeListener(_phoneChanged);
    joystickOn.removeListener(_settingsChanged);
    termPalette.removeListener(_paletteChanged);
    keyPages.removeListener(_settingsChanged);
    termFontSize.removeListener(_fontSizeChanged);
    _histScroll.dispose();
    _keysPage.dispose();
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
    if (_exited || !mounted || _reconnecting || _lostError != null) return;
    if (widget.reconnect == null) return _exit(msg);
    _why = msg;
    _reconnectLoop();
  }

  /// Retries at once, then after 1, 2, 4, 8, 15, 15... s (or right away when the network comes back /
  /// the app resumes) for about 5 minutes.
  Future<void> _reconnectLoop() async {
    setState(() {
      _reconnecting = true;
      _tries = 0;
      _rttMs = null;
    });
    _sub.cancel();
    client.close().catchError((_) {});
    _ssh?.close();
    final until = clock.now().add(const Duration(minutes: 5)); // clock: fake time in tests
    var delay = 0;
    Object? error;
    while (clock.now().isBefore(until)) {
      final kick = _kick = Completer<void>();
      await Future.any([Future<void>.delayed(Duration(seconds: delay)), kick.future]);
      delay = delay == 0 ? 1 : min(delay * 2, 15);
      if (!mounted || _exited) return;
      setState(() => _tries++);
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
        if (e is HostKeyError) break; // a refused key stays refused
      }
    }
    if (mounted) {
      setState(() {
        _reconnecting = false;
        _lostError = '$error';
        _lostKey = error is HostKeyError;
      });
    }
  }

  /// After a reconnect: same window/pane if they still exist, panes reseeded, size/zoom re-sent.
  Future<void> _restore() async {
    _colorsSent.clear(); // a new client: tell tmux again
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
        if (followActive.value && e.windowId == _winId && e.paneId != _paneId) {
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

  void _exit(String? msg) {
    if (_exited || !mounted) return;
    _exited = true;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (msg != null) messenger.showSnackBar(SnackBar(content: Text(msg)));
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
      if (_winId == null || _window == null || (followActive.value && !keepIds) || _jumpToActive) _winId = active.id;
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
    _reportColors();
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
          t.write((_filters[t] ??= TermFilter(blend: _blend)).add(s));
        } finally {
          _writing = false;
        }
      };

  static bool _blend() => blendBackgrounds.value && !termPalette.value.light;

  /// tmux answers programs' OSC 10/11 colour queries (nvim, Claude Code pick light or dark from them);
  /// tell it this theme's colours for every pane, once per pane and theme.
  final _colorsSent = <int>{};
  void _reportColors() {
    final t = termPalette.value;
    for (final id in _panes.keys) {
      if (!_colorsSent.add(id)) continue;
      client.reportColor(id, '10;${oscColor(t.fg)}').then((_) {}, onError: (_) {}); // old tmux: no -r
      client.reportColor(id, '11;${oscColor(t.bg)}').then((_) {}, onError: (_) {});
    }
  }

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
    t.write(TermFilter(blend: _blend).add(text));
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
        color: Tone.ground.withValues(alpha: 0.7),
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
                      style: TextStyle(fontSize: 16, color: e.key == _scrubAt ? Tone.onAccent : Tone.text),
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
      if (_pinching && _phone) termFontSize.set(_font);
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

  /// Switcher: every session of this host, the current one open to its windows.
  void _sheet() {
    final open = <String>{_session};
    showGlassSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: FutureBuilder<List<SessionInfo>>(
            future: client.listSessions(),
            builder: (ctx, snap) {
              final sessions = snap.data ?? const <SessionInfo>[];
              Widget windowRow(int index, String name, String sub, bool current, Widget? map, VoidCallback onTap) =>
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      onTap();
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      color: current ? accent.withValues(alpha: 0.08) : null,
                      padding: const EdgeInsets.fromLTRB(28, 8, 16, 8),
                      child: Row(children: [
                        SizedBox(
                            width: 22,
                            child: Text('$index',
                                style: TextStyle(
                                    fontFamily: termFont.value, fontSize: 12, color: current ? accent : Tone.muted))),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: termFont.value,
                                    fontSize: 14,
                                    fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                                    color: current ? accent : Tone.text)),
                            Text(sub, style: TextStyle(fontSize: 12, color: Tone.muted)),
                          ]),
                        ),
                        ?map,
                      ]),
                    ),
                  );
              return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 0, 12),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Tone.text)),
                        Text(
                            [if (_rttMs case final ms?) '$ms ms', if (snap.hasData) '${sessions.length} sessions']
                                .join(' · '),
                            style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted)),
                      ]),
                    ),
                    _DockKey(
                        tooltip: 'Overview',
                        icon: Icons.grid_view_rounded,
                        onTap: () {
                          Navigator.pop(ctx);
                          _openOverview();
                        }),
                    const SizedBox(width: 8),
                    _DockKey(
                        tooltip: 'Settings',
                        icon: Icons.tune_rounded,
                        onTap: () {
                          Navigator.pop(ctx);
                          openSettings(context);
                        }),
                  ]),
                ),
                if (!snap.hasData) LinearProgressIndicator(minHeight: 1, color: accent),
                for (final s in sessions) ...[
                  Group(color: Tone.raised.withValues(alpha: 0.75), children: [
                    InkWell(
                      onTap: () => setSheet(() => open.contains(s.name) ? open.remove(s.name) : open.add(s.name)),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(children: [
                          Expanded(
                            child: Text(s.name,
                                style: TextStyle(
                                    fontFamily: termFont.value,
                                    fontSize: 15,
                                    fontWeight: s.name == _session ? FontWeight.w600 : FontWeight.w500,
                                    color: s.name == _session ? accent : Tone.text)),
                          ),
                          Text('${s.windows} window${s.windows == 1 ? '' : 's'}',
                              style: TextStyle(fontSize: 12, color: Tone.muted)),
                          const SizedBox(width: 6),
                          Icon(open.contains(s.name) ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                              size: 20, color: Tone.muted),
                        ]),
                      ),
                    ),
                    if (open.contains(s.name) && s.name == _session) ...[
                      for (final w in _windows)
                        windowRow(
                          w.index,
                          w.name,
                          '${w.panes.length} pane${w.panes.length == 1 ? '' : 's'}${w.id == _winId ? ' · you are here' : ''}',
                          w.id == _winId,
                          SizedBox(
                              width: 34,
                              height: 24,
                              child: MiniMap(panes: w.panes, currentId: w.activePane, size: const Size(34, 24))),
                          () => _selectWindow(w.id),
                        ),
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _run(client.newWindow());
                        },
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          padding: const EdgeInsets.only(left: 28),
                          child: Row(children: [
                            Icon(Icons.add_rounded, size: 18, color: accent),
                            const SizedBox(width: 10),
                            Text('New window', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent)),
                          ]),
                        ),
                      ),
                    ] else if (open.contains(s.name))
                      FutureBuilder<List<(int, String, int)>>(
                        future: client.listWindowsOf(s.name),
                        builder: (ctx, ws) => Column(children: [
                          if (!ws.hasData) LinearProgressIndicator(minHeight: 1, color: accent),
                          for (final (idx, name, panes) in ws.data ?? const <(int, String, int)>[])
                            windowRow(idx, name, '$panes pane${panes == 1 ? '' : 's'}', false, null,
                                () => _run(client.switchTo(s.name, idx))),
                        ]),
                      ),
                  ]),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 4),
                PillButton('New session', icon: Icons.add_rounded, primary: false, onPressed: () async {
                  Navigator.pop(ctx);
                  final name = await _askName('New session');
                  if (name != null && name.isNotEmpty) _run(client.newSession(name));
                }),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Future<String?> _askName(String title, [String initial = '']) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Tone.text)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: TextStyle(fontFamily: termFont.value, color: Tone.text),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: Tone.text))),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _renameWindow(WindowInfo w) async {
    final name = await _askName('Rename window', w.name);
    if (name != null && name.isNotEmpty && name != w.name) _run(client.renameWindow(w.id, name));
  }

  Future<void> _killWindow(WindowInfo w) async {
    final n = w.panes.length;
    if (await confirmDanger(context,
        title: 'Kill window “${w.name}”?',
        body: '$n pane${n == 1 ? '' : 's'} and ${n == 1 ? 'its process stops' : 'their processes stop'}. '
            'This can’t be undone.',
        action: 'Kill')) {
      _run(client.killWindow(w.id));
    }
  }

  /// Long-press on a window tab.
  void _windowMenu(WindowInfo w) {
    HapticFeedback.mediumImpact();
    showGlassSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Text('${w.index} ${w.name}',
                  style: TextStyle(fontFamily: termFont.value, fontSize: 17, fontWeight: FontWeight.w600, color: Tone.text)),
            ),
            Group(color: Tone.raised.withValues(alpha: 0.75), children: [
              NavRow(
                  title: 'Rename window',
                  icon: Icons.edit_rounded,
                  onTap: () {
                    Navigator.pop(ctx);
                    _renameWindow(w);
                  }),
              NavRow(
                  title: 'Kill window…',
                  icon: Icons.delete_outline_rounded,
                  color: Tone.danger,
                  onTap: () {
                    Navigator.pop(ctx);
                    _killWindow(w);
                  }),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Hold the minimap: what to do with the shown pane.
  void _actions() {
    final id = _paneId, w = _window, r = _termRect;
    if (id == null || w == null) return;
    HapticFeedback.mediumImpact();
    void act(BuildContext ctx, Future<void> Function() f) {
      Navigator.pop(ctx);
      _run(f());
    }

    Widget tile(BuildContext ctx, IconData icon, String label, Future<void> Function() f) => Material(
          color: Tone.raised.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => act(ctx, f),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Icon(icon, size: 22, color: accent),
                Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.text)),
              ]),
            ),
          ),
        );

    showGlassSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
              child: Row(children: [
                MiniMap(panes: w.panes, currentId: id, size: const Size(30, 40)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text.rich(TextSpan(children: [
                      TextSpan(text: _commands[id] ?? 'pane'),
                      TextSpan(text: '  %$id', style: TextStyle(fontWeight: FontWeight.w400, color: Tone.muted)),
                    ]),
                        style: TextStyle(
                            fontFamily: termFont.value, fontSize: 17, fontWeight: FontWeight.w600, color: Tone.text)),
                    Text('${w.name}${r == null ? '' : ' · ${r.w} × ${r.h}'}',
                        style: TextStyle(fontSize: 13, color: Tone.muted)),
                  ]),
                ),
              ]),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              children: [
                tile(ctx, Icons.vertical_split_outlined, 'Split right', () => client.split(id, horizontal: true)),
                tile(ctx, Icons.horizontal_split_outlined, 'Split down', () => client.split(id, horizontal: false)),
                tile(ctx, Icons.open_in_full_rounded, _phone ? 'Zoom on server' : 'Toggle zoom', () => client.toggleZoom(id)),
                tile(ctx, Icons.add_box_outlined, 'New window', client.newWindow),
              ],
            ),
            const SizedBox(height: 10),
            Group(color: Tone.raised.withValues(alpha: 0.75), children: [
              NavRow(
                  title: 'Rename window',
                  onTap: () {
                    Navigator.pop(ctx);
                    _renameWindow(w);
                  }),
              if (w.panes.length > 1)
                NavRow(title: 'Move pane to new window', onTap: () => act(ctx, () => client.breakPane(id))),
              NavRow(
                  title: 'Kill pane…',
                  icon: Icons.delete_outline_rounded,
                  color: Tone.danger,
                  onTap: () async {
                    Navigator.pop(ctx);
                    if (await confirmDanger(context,
                        title: 'Kill this pane?',
                        body: '${_commands[id] ?? 'Its process'} stops. This can’t be undone.',
                        action: 'Kill')) {
                      _run(client.killPane(id));
                    }
                  }),
            ]),
          ]),
        ),
      ),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final kb = _keyboardUp;
    return Scaffold(
      body: SafeArea(
        bottom: false, // the bar paints under the navigation bar
        child: Stack(fit: StackFit.expand, children: [
          Column(children: [
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _terminalArea())),
            // Context row + keys next to the thumb, on a surface one step above the terminal.
            DecoratedBox(
              decoration: BoxDecoration(
                color: Tone.surface,
                border: Border(top: BorderSide(color: Tone.line, width: 0.5)),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, kb ? 4 : 6, 8, (kb ? 6 : 6) + MediaQuery.paddingOf(context).bottom),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (kb) _whereStrip() else _contextRow(),
                  SizedBox(height: kb ? 4 : 8),
                  _keyRow(),
                  if (!kb && _keyPagesShown.length > 1) _pageDots(),
                ]),
              ),
            ),
          ]),
          if (_scrubFrom != null) _scrubOverlay(),
          if (_lostError != null) _lostCard(),
        ]),
      ),
    );
  }

  double _barDx = 0;

  /// Link health: round circle under 150 ms, square under 400, diamond above (shape, not colour alone).
  Widget _linkDot() {
    final ms = _rttMs;
    final (color, radius, turns) = _reconnecting || ms == null
        ? (Tone.warn, 1.0, 0.0)
        : ms < 150
            ? (termPalette.value.ansi[10], 4.0, 0.0)
            : ms < 400
                ? (Tone.warn, 1.0, 0.0)
                : (Tone.danger, 1.0, 0.125);
    return RotationTransition(
      turns: AlwaysStoppedAnimation(turns),
      child: Container(
          width: 7, height: 7, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius))),
    );
  }

  /// Session chip, window tabs, minimap, keyboard. Swipe the row to step windows.
  Widget _contextRow() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Distance OR velocity: a slow drag that stops before lifting has ~0 velocity.
      onHorizontalDragStart: (_) => _barDx = 0,
      onHorizontalDragUpdate: (d) => _barDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        final dx = v.abs() > 200 ? v : _barDx;
        if (dx.abs() > 200 || _barDx.abs() > 60) _stepWindow(dx < 0 ? 1 : -1);
      },
      child: SizedBox(
        height: 44,
        child: Row(children: [
          Semantics(
            button: true,
            label: 'Session $_session, switch',
            child: Material(
              color: Tone.raised,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _sheet,
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _linkDot(),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(_session,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: termFont.value, fontSize: 13, fontWeight: FontWeight.w500, color: Tone.text)),
                    ),
                    Icon(Icons.expand_more_rounded, size: 16, color: Tone.muted),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Tabs share the row (no scrolling: a sideways swipe here steps windows).
          Expanded(
            child: Row(children: [
              for (final w in _windows)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Material(
                      color: w.id == _winId ? accent.withValues(alpha: 0.14) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          if (w.id != _winId) _selectWindow(w.id);
                        },
                        onLongPress: () => _windowMenu(w),
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          constraints: const BoxConstraints(maxWidth: 140),
                          child: Center(
                            widthFactor: 1,
                            child: Text('${w.index} ${w.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: termFont.value,
                                    fontSize: 13,
                                    fontWeight: w.id == _winId ? FontWeight.w600 : FontWeight.w400,
                                    color: w.id == _winId ? accent : Tone.muted)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 6),
          MiniMap(
            panes: _rects,
            currentId: _paneId,
            size: const Size(26, 34), // phone-shaped
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
          const SizedBox(width: 6),
          _DockKey(
            tooltip: 'Show keyboard',
            icon: Icons.keyboard_rounded,
            flat: true,
            onTap: () => _showKeyboard(_panes[_paneId]),
          ),
        ]),
      ),
    );
  }

  /// While typing: where you are, in one line (the context row folds away).
  Widget _whereStrip() {
    final w = _window, i = _rects.indexWhere((p) => p.id == _paneId);
    return SizedBox(
      height: 20,
      child: Row(children: [
        const SizedBox(width: 4),
        _linkDot(),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$_session › ${w?.name ?? '…'}${_rects.length > 1 && i >= 0 ? ' · pane ${i + 1} of ${_rects.length}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: termFont.value, fontSize: 11, color: Tone.muted),
          ),
        ),
        InkWell(
          onTap: () => _panes[_paneId]?.focus.unfocus(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.keyboard_hide_rounded, size: 18, color: Tone.muted, semanticLabel: 'Hide keyboard'),
          ),
        ),
      ]),
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
            if (h == null) ..._edgeHints(),
            if (_reconnecting) _reconnectBanner(),
          ]),
        );
        if (!joystickOn.value || h != null) return area; // history: the LIVE chip sits there
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

  Widget _reconnectBanner() => Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(
            color: Color.alphaBlend(Tone.warn.withValues(alpha: 0.12), Tone.surface),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Tone.warn.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Tone.warn)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Reconnecting${_tries > 1 ? ' · try $_tries' : '…'}',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Tone.warn)),
                if (_why != null)
                  Text(_why!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Tone.muted)),
              ]),
            ),
            TextButton(
              onPressed: _probe,
              style: TextButton.styleFrom(foregroundColor: Tone.warn, minimumSize: const Size(48, 40)),
              child: const Text('Now', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );

  /// Read-only tmux history over the live view, starting at the bottom (xterm sticks to the bottom).
  Widget _historyView(Terminal t, double font) => Stack(children: [
        Positioned.fill(
          child: ColoredBox(
            color: Tone.ground.withValues(alpha: 0.96),
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
        // How far back: lines above the live bottom.
        Align(
          alignment: Alignment.topCenter,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: _histScroll,
              builder: (context, _) {
                final pos = _histScroll.hasClients ? _histScroll.position : null;
                final back = pos != null && pos.hasContentDimensions ? (pos.extentAfter / _lineH).round() : 0;
                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Tone.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Tone.info.withValues(alpha: 0.4)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.arrow_upward_rounded, size: 14, color: Tone.info),
                    const SizedBox(width: 6),
                    Text('History · $back lines up', style: TextStyle(fontSize: 13, color: Tone.info)),
                  ]),
                );
              },
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Tone.info,
              foregroundColor: Tone.ground,
              minimumSize: const Size(0, 48),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            onPressed: _closeHistory,
            icon: const Icon(Icons.vertical_align_bottom_rounded, size: 20),
            label: const Text('Back to live'),
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

  final _keysPage = PageController();
  int _keysPageAt = 0;

  static const _termKeys = {
    'esc': TerminalKey.escape, 'tab': TerminalKey.tab, 'left': TerminalKey.arrowLeft, //
    'down': TerminalKey.arrowDown, 'up': TerminalKey.arrowUp, 'right': TerminalKey.arrowRight,
    'home': TerminalKey.home, 'end': TerminalKey.end, 'pgup': TerminalKey.pageUp, 'pgdn': TerminalKey.pageDown,
    'f1': TerminalKey.f1, 'f2': TerminalKey.f2, 'f3': TerminalKey.f3, 'f4': TerminalKey.f4,
    'f5': TerminalKey.f5, 'f6': TerminalKey.f6, 'f7': TerminalKey.f7, 'f8': TerminalKey.f8,
    'f9': TerminalKey.f9, 'f10': TerminalKey.f10, 'f11': TerminalKey.f11, 'f12': TerminalKey.f12,
  };

  /// One key of the row (see keys.dart for the ids).
  Widget _rowKey(String id) {
    final label = keyLabel(id);
    final tk = _termKeys[id];
    if (tk != null) {
      final arrow = arrowIcons[id];
      return _DockKey(label: label, icon: arrow, repeat: arrow != null || id.startsWith('pg'), onTap: () => _key(tk));
    }
    if (id == 'ctrl') return _DockKey(label: 'Ctrl', on: _ctrl, onTap: () => setState(() => _ctrl = !_ctrl));
    if (id == 'alt') return _DockKey(label: 'Alt', on: _alt, onTap: () => setState(() => _alt = !_alt));
    if (id == 'paste') return _DockKey(label: 'Paste', onTap: _paste);
    if (ctrlByte(id) case final b?) return _DockKey(label: label, onTap: () => _bytes([b]));
    if (snippetOf(id) case (_, final text)) {
      return _DockKey(label: label, onTap: () => _text(text.replaceAll('\r\n', '\r').replaceAll('\n', '\r')));
    }
    return _DockKey(label: label, onTap: () => _text(id));
  }

  List<List<String>> get _keyPagesShown => [for (final p in keyPages.value) if (p.isNotEmpty) p];

  /// Up to eight equal keys a page (Settings › Key row); swipe sideways for the next page.
  Widget _keyRow() {
    final pages = _keyPagesShown;
    return SizedBox(
      height: 44,
      child: PageView(
        controller: _keysPage,
        onPageChanged: (i) => setState(() => _keysPageAt = i),
        children: [
          for (final keys in pages)
            Row(children: [
              for (var i = 0; i < keys.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(child: _rowKey(keys[i])),
              ],
            ]),
        ],
      ),
    );
  }

  Widget _pageDots() => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < _keyPagesShown.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _keysPageAt ? 14 : 4,
              height: 4,
              decoration: BoxDecoration(
                color: i == _keysPageAt ? Tone.text : Tone.faint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ]),
      );

  // ---------- connection lost ----------

  Widget _lostCard() => Positioned.fill(
        child: ColoredBox(
          color: Tone.ground.withValues(alpha: 0.82),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                decoration: BoxDecoration(
                  color: Tone.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Tone.line),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                          color: Tone.danger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                      child: Icon(Icons.wifi_off_rounded, color: Tone.danger),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(_lostKey ? 'Not connected to ${widget.title}' : 'Can’t reach ${widget.title}',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Tone.text)),
                  const SizedBox(height: 8),
                  Text(
                      _lostKey
                          ? 'The server’s key was not trusted. Your tmux session keeps running on the server.'
                          : 'Tried for 5 minutes. Your tmux session keeps running on the server; nothing there is lost.',
                      style: TextStyle(fontSize: 15, height: 1.45, color: Tone.muted)),
                  const SizedBox(height: 8),
                  Text(_lostError!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted)),
                  const SizedBox(height: 18),
                  PillButton('Try again', icon: Icons.refresh_rounded, onPressed: () {
                    setState(() => _lostError = null);
                    _reconnectLoop();
                  }),
                  const SizedBox(height: 8),
                  PillButton('All hosts', primary: false, onPressed: () => _exit(null)),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// A key cap / bar button: flat raised fill (none when [flat]), accent when [on] (sticky Ctrl/Alt,
/// keyboard up), dims and shrinks a little while pressed. [repeat]: fires every 70 ms while held.
class _DockKey extends StatefulWidget {
  final String? label, tooltip;
  final IconData? icon;
  final bool on, repeat, flat;
  final VoidCallback onTap;
  const _DockKey(
      {this.label, this.icon, this.tooltip, this.on = false, this.repeat = false, this.flat = false, required this.onTap});
  @override
  State<_DockKey> createState() => _DockKeyState();
}

class _DockKeyState extends State<_DockKey> {
  bool _down = false;
  Timer? _repeat;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
    if (!down) {
      _repeat?.cancel();
      _repeat = null;
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    final fg = on ? Tone.onAccent : widget.flat ? Tone.muted : Tone.text;
    final fill = on
        ? accent
        : widget.flat
            ? (_down ? Tone.raised : Colors.transparent)
            : (_down ? Tone.pressed : Tone.raised);
    final cap = AnimatedScale(
      scale: _down ? 0.94 : 1,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: widget.label == null ? 44 : 42,
        constraints: widget.label == null ? const BoxConstraints(minWidth: 44) : null,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
        child: widget.icon != null
            ? Icon(widget.icon, size: widget.label == null ? 22 : 18, color: fg)
            : FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(widget.label!,
                      style: TextStyle(
                          fontFamily: termFont.value,
                          fontSize: 14,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          color: fg)),
                ),
              ),
      ),
    );
    final g = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press(true),
      onTapCancel: () => _press(false),
      onTapUp: (_) => _press(false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onLongPressStart: widget.repeat
          ? (_) {
              _press(true);
              widget.onTap();
              _repeat = Timer.periodic(const Duration(milliseconds: 70), (_) => widget.onTap());
            }
          : null,
      onLongPressEnd: widget.repeat ? (_) => _press(false) : null,
      child: cap,
    );
    final t = widget.tooltip;
    return Semantics(
      button: true,
      label: t ?? widget.label,
      child: t == null ? g : Tooltip(message: t, child: g),
    );
  }
}

/// Slim translucent label over the terminal (edge hints).
class _Pill extends StatelessWidget {
  final String text;
  const _Pill(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(6),
        child: Glass(
          radius: const BorderRadius.all(Radius.circular(14)),
          blur: 12,
          strength: 0.6,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Text(text, style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted)),
        ),
      );
}
