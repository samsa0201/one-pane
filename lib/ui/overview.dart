import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../tmux/control.dart';
import '../tmux/layout.dart';
import 'glass.dart';
import 'minimap.dart';

/// What the user picked in the overview / session map. Exactly one field is set.
class OverviewResult {
  final int? paneId;
  final int? windowId;
  final String? session;
  const OverviewResult({this.paneId, this.windowId, this.session});
}

/// Calls [onPinchIn] / [onPinchOut] when a two-finger pinch ends past the thresholds.
class _Pinch extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPinchIn, onPinchOut;
  const _Pinch({required this.child, this.onPinchIn, this.onPinchOut});
  @override
  State<_Pinch> createState() => _PinchState();
}

class _PinchState extends State<_Pinch> {
  double _scale = 1;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onScaleStart: (_) => _scale = 1,
        onScaleUpdate: (d) {
          if (d.pointerCount == 2) _scale = d.scale;
        },
        onScaleEnd: (_) {
          if (_scale < 0.7) widget.onPinchIn?.call();
          if (_scale > 1.4) widget.onPinchOut?.call();
          _scale = 1;
        },
        child: widget.child,
      );
}

/// Last [n] non-trailing-blank lines of the terminal's visible screen.
List<String> tailLines(Terminal t, int n) {
  final lines = t.buffer.lines;
  final start = (lines.length - t.viewHeight).clamp(0, lines.length);
  final out = [for (var i = start; i < lines.length; i++) lines[i].toString().trimRight()];
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.length > n ? out.sublist(out.length - n) : out;
}

class WindowOverview extends StatelessWidget {
  final TmuxClient client;
  final String session;
  final WindowInfo window;
  final int? currentPane;
  final Map<int, Terminal> terminals;

  const WindowOverview({
    super.key,
    required this.client,
    required this.session,
    required this.window,
    required this.currentPane,
    required this.terminals,
  });

  @override
  Widget build(BuildContext context) {
    Future<void> sessions() async {
      final r = await Navigator.push<OverviewResult>(
        context,
        MaterialPageRoute(builder: (_) => SessionMap(client: client, session: session)),
      );
      if (r != null && context.mounted) Navigator.pop(context, r);
    }

    return Scaffold(
      appBar: AppBar(title: Text('$session › ${window.index}:${window.name}'), actions: [
        IconButton(tooltip: 'Sessions', icon: const Icon(Icons.view_module), onPressed: sessions),
      ]),
      body: _Pinch(
        onPinchOut: () => Navigator.pop(context),
        onPinchIn: sessions,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(builder: (context, c) {
            final rects = scaleRects(window.panes, c.biggest);
            return Stack(children: [
              for (final e in rects.entries)
                Positioned.fromRect(
                  rect: e.value.deflate(2),
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, OverviewResult(paneId: e.key)),
                    child: _PaneThumb(
                      id: e.key,
                      terminal: terminals[e.key],
                      current: e.key == currentPane,
                      height: e.value.height,
                    ),
                  ),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

class _PaneThumb extends StatelessWidget {
  final int id;
  final Terminal? terminal;
  final bool current;
  final double height;
  const _PaneThumb({required this.id, required this.terminal, required this.current, required this.height});

  @override
  Widget build(BuildContext context) {
    const lineH = 7.0;
    final n = ((height - 20) / lineH).floor().clamp(0, 200);
    final text = terminal == null ? '' : tailLines(terminal!, n).join('\n');
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      // Smoked glass without a backdrop blur (several live thumbnails): dark tint + rim.
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: current ? accent : Tone.line, width: current ? 1.5 : 1),
        boxShadow: current ? [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 14)] : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('%$id',
            style: TextStyle(
                color: current ? accent : Tone.muted, fontSize: 10, fontWeight: current ? FontWeight.w600 : null)),
        Expanded(
          child: ClipRect(
            child: Text(
              text,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(fontFamily: 'monospace', fontSize: 6, height: lineH / 6, color: Tone.muted),
            ),
          ),
        ),
      ]),
    );
  }
}

/// All windows of the attached session as cards, plus one card per other session.
class SessionMap extends StatefulWidget {
  final TmuxClient client;
  final String session;
  const SessionMap({super.key, required this.client, required this.session});
  @override
  State<SessionMap> createState() => _SessionMapState();
}

class _SessionMapState extends State<SessionMap> {
  List<SessionInfo> _sessions = [];
  List<WindowInfo> _windows = [];

  @override
  void initState() {
    super.initState();
    () async {
      final s = await widget.client.listSessions();
      final w = await widget.client.listWindows();
      if (mounted) {
        setState(() {
          _sessions = s;
          _windows = w;
        });
      }
    }();
  }

  Widget _card(String title, String subtitle, bool active, OverviewResult r, {List<PaneRect>? panes, int? activePane}) => Glass(
        radius: const BorderRadius.all(Radius.circular(20)),
        strength: active ? 1.6 : 1,
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: active ? BorderSide(color: accent, width: 1.5) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
          onTap: () => Navigator.pop(context, r),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (panes != null) ...[
                MiniMap(panes: panes, currentId: activePane, size: const Size(56, 34)),
                const SizedBox(height: 6),
              ] else ...[
                Icon(Icons.dns_outlined, size: 28, color: Tone.muted),
                const SizedBox(height: 6),
              ],
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Tone.muted)),
            ]),
          ),
        ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      for (final w in _windows)
        _card('${w.index}:${w.name}', '${widget.session} · ${w.panes.length} panes', w.active,
            OverviewResult(windowId: w.id),
            panes: w.panes, activePane: w.activePane),
      for (final s in _sessions.where((s) => s.name != widget.session))
        _card(s.name, '${s.windows} windows', false, OverviewResult(session: s.name)),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Sessions')),
      body: _Pinch(
        onPinchOut: () => Navigator.pop(context),
        child: GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(8), children: cards),
      ),
    );
  }
}
