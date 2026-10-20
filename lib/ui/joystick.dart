import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tmux/layout.dart';
import 'minimap.dart' show accent;

/// Direction the knob points to (literal: pushed right → right), null inside the dead zone.
Dir? stickDir(Offset knob, {double dead = 18}) {
  if (knob.distance < dead) return null;
  if (knob.dx.abs() >= knob.dy.abs()) return knob.dx > 0 ? Dir.right : Dir.left;
  return knob.dy > 0 ? Dir.down : Dir.up;
}

const _switchColor = Color(0xFFFFB74D);

/// Floating one-thumb navigator.
/// - push the knob toward a side and let go → [onMove] (pane); chevrons show sides with a neighbour
/// - double tap and slide: sideways → [onWindow] ±1, up/down → [onSession] ±1
/// - tap → [onTap] (after the double-tap window); hold, then drag → [onDragBy] moves the stick itself
class Joystick extends StatefulWidget {
  final Set<Dir> available;
  final ValueChanged<Dir> onMove;
  final ValueChanged<int>? onWindow, onSession;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onDragBy;
  final VoidCallback? onDragEnd;
  const Joystick({
    super.key,
    required this.available,
    required this.onMove,
    this.onWindow,
    this.onSession,
    this.onTap,
    this.onDragBy,
    this.onDragEnd,
  });
  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  static const _size = 72.0, _knobSize = 30.0, _reach = 22.0;
  static const _doubleTap = Duration(milliseconds: 300);
  var _knob = Offset.zero;
  Dir? _dir;
  bool _switch = false; // second touch of a double tap: window / session mode
  bool _moving = false; // held: dragging the stick around
  DateTime _lastTap = DateTime(0);
  Timer? _tapTimer;
  Offset _held = Offset.zero;

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  void _down(PointerDownEvent _) {
    if (DateTime.now().difference(_lastTap) < _doubleTap) {
      _tapTimer?.cancel();
      setState(() => _switch = true);
    }
  }

  void _tap() {
    if (_switch) {
      setState(() => _switch = false); // plain double tap: nothing
      return;
    }
    _lastTap = DateTime.now();
    _tapTimer = Timer(_doubleTap, () => widget.onTap?.call());
  }

  void _drag(Offset delta) {
    var k = _knob + delta;
    if (k.distance > _reach) k = k / k.distance * _reach;
    final d = stickDir(k);
    if (d != _dir && d != null) HapticFeedback.selectionClick();
    setState(() {
      _knob = k;
      _dir = d;
    });
  }

  void _release() {
    final d = _dir, sw = _switch;
    setState(() {
      _knob = Offset.zero;
      _dir = null;
      _switch = false;
    });
    if (d == null) return;
    if (!sw) return widget.onMove(d);
    switch (d) {
      case Dir.left || Dir.right:
        widget.onWindow?.call(d == Dir.right ? 1 : -1);
      case Dir.up || Dir.down:
        widget.onSession?.call(d == Dir.down ? 1 : -1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _switch ? _switchColor : accent;
    Widget chevron(Dir d, Alignment a, IconData icon) => Align(
          alignment: a,
          child: Icon(icon,
              size: 18,
              color: _dir == d
                  ? color
                  : _switch || widget.available.contains(d)
                      ? Colors.white70
                      : Colors.white12),
        );
    final label = !_switch || _dir == null ? null : (_dir == Dir.left || _dir == Dir.right ? 'W' : 'S');
    return Listener(
      onPointerDown: _down,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        onPanStart: (_) => _drag(Offset.zero),
        onPanUpdate: (d) => _drag(d.delta),
        onPanEnd: (_) => _release(),
        onPanCancel: _release,
        onLongPressStart: (_) {
          HapticFeedback.mediumImpact();
          _held = Offset.zero;
          setState(() {
            _moving = true;
            _switch = false;
          });
        },
        onLongPressMoveUpdate: (d) {
          widget.onDragBy?.call(d.offsetFromOrigin - _held);
          _held = d.offsetFromOrigin;
        },
        onLongPressEnd: (_) {
          setState(() => _moving = false);
          widget.onDragEnd?.call();
        },
        child: AnimatedScale(
          scale: _moving ? 1.15 : 1,
          duration: const Duration(milliseconds: 120),
          child: Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0x991A1C1E),
              border: Border.all(color: _moving || _switch ? color : Colors.white24),
            ),
            child: Stack(children: [
              chevron(Dir.up, Alignment.topCenter, Icons.keyboard_arrow_up),
              chevron(Dir.down, Alignment.bottomCenter, Icons.keyboard_arrow_down),
              chevron(Dir.left, Alignment.centerLeft, Icons.keyboard_arrow_left),
              chevron(Dir.right, Alignment.centerRight, Icons.keyboard_arrow_right),
              Center(
                child: Transform.translate(
                  offset: _knob,
                  child: Container(
                    width: _knobSize,
                    height: _knobSize,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dir == null
                          ? (_switch ? _switchColor.withValues(alpha: 0.5) : Colors.white24)
                          : color.withValues(alpha: 0.85),
                    ),
                    child: label == null
                        ? null
                        : Text(label,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
