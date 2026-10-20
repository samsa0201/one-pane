import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/ui/fonts.dart';

void main() {
  test('font file signature', () {
    expect(isFontFile([0, 1, 0, 0]), isTrue); // TrueType
    expect(isFontFile('OTTO'.codeUnits), isTrue); // OpenType CFF
    expect(isFontFile('<!DO'.codeUnits), isFalse); // an HTML error page
    expect(isFontFile([0, 1]), isFalse);
  });

  test('catalogue: Hack bundled first, the rest are Nerd Font Mono files with a bold', () {
    expect(termFonts.first.bundled, isTrue);
    for (final f in termFonts.skip(1)) {
      expect(f.regular, contains('NerdFontMono-Regular.ttf'));
      expect(f.bold, contains('NerdFontMono-Bold.ttf'));
    }
    expect(termFonts.map((f) => f.family).toSet().length, termFonts.length);
  });
}
