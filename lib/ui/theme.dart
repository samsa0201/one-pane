import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

/// A terminal colour scheme. The app's chrome takes its tones from it ([Tone]), so the terminal and
/// the bars around it are one surface whatever the scheme.
class TermPalette {
  final String name;
  final Color bg, fg, accent, cursor;

  /// ANSI 0–15: black red green yellow blue magenta cyan white, then the bright ones.
  final List<Color> ansi;
  const TermPalette(this.name, {required this.bg, required this.fg, required this.accent, Color? cursor, required this.ansi})
      : cursor = cursor ?? accent;
  bool get light => bg.computeLuminance() > 0.4;
}

const palettes = [
  TermPalette('Ink', bg: Color(0xFF0D0E12), fg: Color(0xFFD6D8DE), accent: Color(0xFF7EE0B8), ansi: [
    Color(0xFF2A2C33), Color(0xFFF07178), Color(0xFF9CD88A), Color(0xFFE6C47A), //
    Color(0xFF7AA9F0), Color(0xFFC79BEA), Color(0xFF7FD3D8), Color(0xFFD6D8DE),
    Color(0xFF6B6F7A), Color(0xFFFF8B92), Color(0xFFB4EBA3), Color(0xFFF2D693),
    Color(0xFF99BFFA), Color(0xFFD8B4F5), Color(0xFF9AE3E7), Color(0xFFFFFFFF),
  ]),
  TermPalette('Gruvbox', bg: Color(0xFF282828), fg: Color(0xFFEBDBB2), accent: Color(0xFFFABD2F), ansi: [
    Color(0xFF282828), Color(0xFFCC241D), Color(0xFF98971A), Color(0xFFD79921), //
    Color(0xFF458588), Color(0xFFB16286), Color(0xFF689D6A), Color(0xFFA89984),
    Color(0xFF928374), Color(0xFFFB4934), Color(0xFFB8BB26), Color(0xFFFABD2F),
    Color(0xFF83A598), Color(0xFFD3869B), Color(0xFF8EC07C), Color(0xFFEBDBB2),
  ]),
  TermPalette('Catppuccin', bg: Color(0xFF1E1E2E), fg: Color(0xFFCDD6F4), accent: Color(0xFFCBA6F7), cursor: Color(0xFFF5E0DC), ansi: [
    Color(0xFF45475A), Color(0xFFF38BA8), Color(0xFFA6E3A1), Color(0xFFF9E2AF), //
    Color(0xFF89B4FA), Color(0xFFF5C2E7), Color(0xFF94E2D5), Color(0xFFBAC2DE),
    Color(0xFF585B70), Color(0xFFF38BA8), Color(0xFFA6E3A1), Color(0xFFF9E2AF),
    Color(0xFF89B4FA), Color(0xFFF5C2E7), Color(0xFF94E2D5), Color(0xFFA6ADC8),
  ]),
  TermPalette('Tokyo Night', bg: Color(0xFF1A1B26), fg: Color(0xFFC0CAF5), accent: Color(0xFF7AA2F7), ansi: [
    Color(0xFF15161E), Color(0xFFF7768E), Color(0xFF9ECE6A), Color(0xFFE0AF68), //
    Color(0xFF7AA2F7), Color(0xFFBB9AF7), Color(0xFF7DCFFF), Color(0xFFA9B1D6),
    Color(0xFF414868), Color(0xFFF7768E), Color(0xFF9ECE6A), Color(0xFFE0AF68),
    Color(0xFF7AA2F7), Color(0xFFBB9AF7), Color(0xFF7DCFFF), Color(0xFFC0CAF5),
  ]),
  TermPalette('Dracula', bg: Color(0xFF282A36), fg: Color(0xFFF8F8F2), accent: Color(0xFFBD93F9), ansi: [
    Color(0xFF21222C), Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFFF1FA8C), //
    Color(0xFFBD93F9), Color(0xFFFF79C6), Color(0xFF8BE9FD), Color(0xFFF8F8F2),
    Color(0xFF6272A4), Color(0xFFFF6E6E), Color(0xFF69FF94), Color(0xFFFFFFA5),
    Color(0xFFD6ACFF), Color(0xFFFF92DF), Color(0xFFA4FFFF), Color(0xFFFFFFFF),
  ]),
  TermPalette('Nord', bg: Color(0xFF2E3440), fg: Color(0xFFD8DEE9), accent: Color(0xFF88C0D0), ansi: [
    Color(0xFF3B4252), Color(0xFFBF616A), Color(0xFFA3BE8C), Color(0xFFEBCB8B), //
    Color(0xFF81A1C1), Color(0xFFB48EAD), Color(0xFF88C0D0), Color(0xFFE5E9F0),
    Color(0xFF4C566A), Color(0xFFBF616A), Color(0xFFA3BE8C), Color(0xFFEBCB8B),
    Color(0xFF81A1C1), Color(0xFFB48EAD), Color(0xFF8FBCBB), Color(0xFFECEFF4),
  ]),
  TermPalette('Solarized Light', bg: Color(0xFFFDF6E3), fg: Color(0xFF586E75), accent: Color(0xFF268BD2), ansi: [
    Color(0xFF073642), Color(0xFFDC322F), Color(0xFF859900), Color(0xFFB58900), //
    Color(0xFF268BD2), Color(0xFFD33682), Color(0xFF2AA198), Color(0xFFEEE8D5),
    Color(0xFF002B36), Color(0xFFCB4B16), Color(0xFF586E75), Color(0xFF657B83),
    Color(0xFF839496), Color(0xFF6C71C4), Color(0xFF93A1A1), Color(0xFFFDF6E3),
  ]),
  TermPalette('One Light', bg: Color(0xFFFAFAFA), fg: Color(0xFF383A42), accent: Color(0xFF4078F2), ansi: [
    Color(0xFF383A42), Color(0xFFE45649), Color(0xFF50A14F), Color(0xFFC18401), //
    Color(0xFF4078F2), Color(0xFFA626A4), Color(0xFF0184BC), Color(0xFFA0A1A7),
    Color(0xFF696C77), Color(0xFFE45649), Color(0xFF50A14F), Color(0xFFC18401),
    Color(0xFF4078F2), Color(0xFFA626A4), Color(0xFF0184BC), Color(0xFFFAFAFA),
  ]),
];

final termPalette = ValueNotifier<TermPalette>(palettes.first);

/// Near-black backgrounds an app paints itself (nvim colour schemes, TUIs) drawn as the theme's.
final blendBackgrounds = ValueNotifier<bool>(true);

const _palettePref = 'termTheme', _blendPref = 'blendBackgrounds';

Future<void> loadThemePrefs() async {
  try {
    final p = await SharedPreferences.getInstance();
    termPalette.value = palettes.where((t) => t.name == p.getString(_palettePref)).firstOrNull ?? palettes.first;
    blendBackgrounds.value = p.getBool(_blendPref) ?? true;
  } catch (_) {}
}

void setPalette(TermPalette t) {
  termPalette.value = t;
  _rebuildAll();
  SharedPreferences.getInstance().then((p) => p.setString(_palettePref, t.name)).catchError((_) => true);
}

void setBlendBackgrounds(bool on) {
  blendBackgrounds.value = on;
  SharedPreferences.getInstance().then((p) => p.setBool(_blendPref, on)).catchError((_) => true);
}

/// [Tone] is read in build methods all over; const widgets would keep the old colours, so every
/// element rebuilds once when the theme changes (rare).
void _rebuildAll() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}

/// The current theme's accent colour (current pane, sticky keys, primary buttons).
Color get accent => termPalette.value.accent;

/// Chrome tones derived from the terminal theme: one ground shared by the terminal and the screen,
/// surfaces one and two steps towards the foreground, hairlines instead of shadows.
abstract final class Tone {
  static TermPalette get _t => termPalette.value;
  static Color get ground => _t.bg;
  static Color get surface => Color.lerp(_t.bg, _t.fg, _t.light ? 0.05 : 0.045)!;
  static Color get raised => Color.lerp(_t.bg, _t.fg, _t.light ? 0.10 : 0.09)!;
  static Color get pressed => Color.lerp(_t.bg, _t.fg, 0.16)!;
  static Color get line => _t.fg.withValues(alpha: 0.10);
  static Color get text => Color.lerp(_t.fg, _t.light ? Colors.black : Colors.white, 0.35)!;
  static Color get muted => Color.lerp(_t.fg, _t.bg, 0.30)!;
  static Color get faint => Color.lerp(_t.fg, _t.bg, 0.55)!;
  static Color get warn => _t.ansi[11];
  static Color get danger => _t.ansi[9];
  static Color get info => _t.ansi[12];
  static Color get onAccent => _t.light ? Colors.white : _t.bg;
}

TerminalTheme get terminalTheme {
  final t = termPalette.value, a = t.ansi;
  return TerminalTheme(
    cursor: t.cursor.withValues(alpha: 0.8),
    selection: t.accent.withValues(alpha: 0.33),
    foreground: t.fg,
    background: t.bg,
    black: a[0],
    red: a[1],
    green: a[2],
    yellow: a[3],
    blue: a[4],
    magenta: a[5],
    cyan: a[6],
    white: a[7],
    brightBlack: a[8],
    brightRed: a[9],
    brightGreen: a[10],
    brightYellow: a[11],
    brightBlue: a[12],
    brightMagenta: a[13],
    brightCyan: a[14],
    brightWhite: a[15],
    searchHitBackground: a[11],
    searchHitBackgroundCurrent: a[10],
    searchHitForeground: t.bg,
  );
}

/// xterm `rgb:rrrr/gggg/bbbb`, the answer to an OSC 10/11/12 colour query.
String oscColor(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0') * 2;
  return 'rgb:${h(c.r)}/${h(c.g)}/${h(c.b)}';
}
