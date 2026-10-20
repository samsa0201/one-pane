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

/// Floating one-thumb navigator: push the knob toward a side and let go → [onMove] that way.
/// Chevrons show the sides that have a neighbour ([available]). Tap → [onTap].
class Joystick extends StatefulWidget {
  final Set<Dir> available;
  final ValueChanged<Dir> onMove;
  final VoidCallback? onTap;
  const Joystick({super.key, required this.available, required this.onMove, this.onTap});
  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  static const _size = 72.0, _knobSize = 30.0, _reach = 22.0;
  var _knob = Offset.zero;
  Dir? _dir;

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
    final d = _dir;
    setState(() {
      _knob = Offset.zero;
      _dir = null;
    });
    if (d != null) widget.onMove(d);
  }

  @override
  Widget build(BuildContext context) {
    Widget chevron(Dir d, Alignment a, IconData icon) => Align(
          alignment: a,
          child: Icon(icon,
              size: 18,
              color: _dir == d
                  ? accent
                  : widget.available.contains(d)
                      ? Colors.white70
                      : Colors.white12),
        );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onPanStart: (_) => _drag(Offset.zero),
      onPanUpdate: (d) => _drag(d.delta),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x991A1C1E),
          border: Border.all(color: Colors.white24),
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
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _dir == null ? Colors.white24 : accent.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
