import 'dart:math';

/// Rewrites terminal output that xterm.dart misreads, before it reaches the Terminal:
/// - CSI with a `>` `<` `=` `?` prefix ending in `m` / `u` is dropped: xterm.dart ignores the prefix, so
///   modifyOtherKeys `ESC[>4;2m` (sent by Claude Code, nvim…) became SGR 4;2 = underline + faint for
///   everything after it, and kitty keyboard `ESC[>1u` / `ESC[<u` a cursor restore.
/// - SGR colon sub-parameters (`4:3`, `38:2::r:g:b`) become semicolon forms; underline colour (58) is
///   dropped: xterm.dart would read its numbers as attributes (a 4 = underline).
/// - [blend]: near-black backgrounds an app sets itself (`48;2;…`, `48;5;…`) become the default
///   background, so a dark colour scheme in nvim or a TUI sits on the theme's own ground.
/// A CSI split across chunks is held back until it is complete.
class TermFilter {
  String _carry = '';
  final bool Function() blend;
  TermFilter({bool Function()? blend}) : blend = blend ?? _never;
  static bool _never() => false;

  static final _csi = RegExp(r'\x1b\[([<=>?]?)([0-9;:]*)([\x20-\x2f]*)([\x40-\x7e])');
  static final _unfinished = RegExp(r'\x1b(\[[<=>?]?[0-9;:]*[\x20-\x2f]*)?$');

  /// Forget a held-back partial sequence (the screen is about to be rewritten).
  void reset() => _carry = '';

  String add(String s) {
    s = _carry + s;
    _carry = '';
    final tail = _unfinished.firstMatch(s);
    if (tail != null) {
      _carry = s.substring(tail.start);
      s = s.substring(0, tail.start);
    }
    if (!s.contains('\x1b[')) return s;
    return s.replaceAllMapped(_csi, (m) {
      final prefix = m[1]!, params = m[2]!, fin = m[4]!;
      if (prefix.isNotEmpty && (fin == 'm' || fin == 'u')) return '';
      if (prefix.isEmpty &&
          m[3]!.isEmpty &&
          fin == 'm' &&
          (params.contains(':') || params.contains('58') || (params.contains('48') && blend()))) {
        final p = sgr(params, blend: blend());
        return p.isEmpty ? '' : '\x1b[${p}m'; // empty would be ESC[m = reset
      }
      return m[0]!;
    });
  }
}

/// SGR parameters with colon sub-parameters and underline colour rewritten for xterm.dart.
String sgr(String params, {bool blend = false}) {
  final out = <String>[];
  final ps = params.split(';');
  for (var i = 0; i < ps.length; i++) {
    final p = ps[i];
    final sub = p.split(':');
    switch (sub[0]) {
      case '4' when sub.length > 1:
        out.add(sub[1] == '0' ? '24' : '4'); // styled underline → plain
      case ('38' || '48') when sub.length > 1:
        final v = sub.skip(1).toList();
        if (v[0] == '5' && v.length > 1) {
          out.addAll([sub[0], '5', v[1]]);
        } else if (v[0] == '2') {
          final rgb = v.skip(1).where((x) => x.isNotEmpty).toList(); // 38:2::r:g:b or 38:2:r:g:b
          if (rgb.length >= 3) {
            final c = rgb.sublist(rgb.length - 3);
            out.addAll(blend && sub[0] == '48' && _nearBlack(c) ? ['49'] : [sub[0], '2', ...c]);
          }
        }
      case '58' when sub.length > 1:
        break; // underline colour, colon form
      case '58':
        // semicolon form: 58;5;n or 58;2;r;g;b
        if (i + 1 < ps.length) i += ps[i + 1] == '5' ? 2 : 4;
      case '38' || '48':
        // semicolon form, kept whole so its numbers are not taken for attributes here
        final n = i + 1 < ps.length && ps[i + 1] == '5' ? 3 : 5;
        final v = ps.sublist(i, (i + n).clamp(0, ps.length));
        final dark = v.length == 3 ? _darkIndex(v[2]) : v.length == 5 && _nearBlack(v.sublist(2));
        out.addAll(blend && p == '48' && dark ? ['49'] : v);
        i += n - 1;
      default:
        if (sub.length == 1) out.add(p);
    }
  }
  return out.join(';');
}

/// A background dark enough to be "the" background in a dark scheme (relative luminance < 3%).
bool _nearBlack(List<String> rgb) {
  final c = [for (final x in rgb) (int.tryParse(x) ?? 255) / 255];
  double lin(double v) => v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]) < 0.03;
}

/// 256-colour black: 0, the cube's black 16 and the darkest greys.
bool _darkIndex(String n) => const {'0', '16', '232', '233', '234', '235', '236'}.contains(n);
