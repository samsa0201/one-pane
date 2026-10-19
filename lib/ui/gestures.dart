import 'dart:ui';

import '../tmux/layout.dart';

/// Direction of a two-finger swipe, by dominant axis; null below [threshold] px.
/// The direction is where the user wants to GO: swiping fingers leftwards
/// (content moves left) reveals the pane on the right.
Dir? swipeDir(Offset delta, {double threshold = 60}) {
  if (delta.distance < threshold) return null;
  if (delta.dx.abs() >= delta.dy.abs()) return delta.dx < 0 ? Dir.right : Dir.left;
  return delta.dy < 0 ? Dir.down : Dir.up;
}

/// Unit offset of the side a pane in direction [d] slides in from.
Offset dirOffset(Dir d) => switch (d) {
      Dir.left => const Offset(-1, 0),
      Dir.right => const Offset(1, 0),
      Dir.up => const Offset(0, -1),
      Dir.down => const Offset(0, 1),
    };
