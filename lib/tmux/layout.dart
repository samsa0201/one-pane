/// tmux window layout strings → pane rectangles, and spatial neighbours.
library;

class PaneRect {
  final int id;
  final int x, y, w, h;
  const PaneRect(this.id, this.x, this.y, this.w, this.h);
  @override
  String toString() => 'PaneRect(%$id ${w}x$h@$x,$y)';
}

/// Parses `8b5f,160x48,0,0{80x48,0,0,0,79x48,81,0,1}` (checksum optional).
List<PaneRect> parseLayout(String layout) {
  var s = layout.trim();
  final m = RegExp(r'^[0-9a-fA-F]{4},').firstMatch(s);
  if (m != null) s = s.substring(m.end);
  final out = <PaneRect>[];
  var i = 0;

  int number() {
    final start = i;
    while (i < s.length && '0123456789'.contains(s[i])) {
      i++;
    }
    if (i == start) throw FormatException('number expected', layout, i);
    return int.parse(s.substring(start, i));
  }

  void expect(String c) {
    if (i >= s.length || s[i] != c) throw FormatException('"$c" expected', layout, i);
    i++;
  }

  void cell() {
    final w = number();
    expect('x');
    final h = number();
    expect(',');
    final x = number();
    expect(',');
    final y = number();
    if (i < s.length && (s[i] == '{' || s[i] == '[')) {
      final close = s[i] == '{' ? '}' : ']';
      i++;
      cell();
      while (i < s.length && s[i] == ',') {
        i++;
        cell();
      }
      expect(close);
    } else {
      expect(',');
      out.add(PaneRect(number(), x, y, w, h));
    }
  }

  cell();
  if (i != s.length) throw FormatException('trailing data', layout, i);
  return out;
}

enum Dir { left, right, up, down }

/// Pane across the border in direction [d] from [fromId], or null at the window edge.
/// Among panes on that side overlapping fromId's span on the other axis: nearest edge first,
/// then max overlap, then top/left closest to fromId's top/left.
int? neighbor(List<PaneRect> panes, int fromId, Dir d) {
  final f = panes.where((p) => p.id == fromId).firstOrNull;
  if (f == null) return null;
  final horiz = d == Dir.left || d == Dir.right;
  int? best;
  (int, int, int)? bestKey; // (gap, -overlap, startDistance), smaller wins
  for (final p in panes) {
    if (p.id == fromId) continue;
    final gap = switch (d) {
      Dir.left => f.x - (p.x + p.w),
      Dir.right => p.x - (f.x + f.w),
      Dir.up => f.y - (p.y + p.h),
      Dir.down => p.y - (f.y + f.h),
    };
    if (gap < 0) continue;
    final (a0, a1, b0, b1) = horiz
        ? (f.y, f.y + f.h, p.y, p.y + p.h)
        : (f.x, f.x + f.w, p.x, p.x + p.w);
    final overlap = (a1 < b1 ? a1 : b1) - (a0 > b0 ? a0 : b0);
    if (overlap <= 0) continue;
    final key = (gap, -overlap, (b0 - a0).abs());
    if (bestKey == null || _less(key, bestKey)) {
      best = p.id;
      bestKey = key;
    }
  }
  return best;
}

bool _less((int, int, int) a, (int, int, int) b) =>
    a.$1 != b.$1 ? a.$1 < b.$1 : a.$2 != b.$2 ? a.$2 < b.$2 : a.$3 < b.$3;
