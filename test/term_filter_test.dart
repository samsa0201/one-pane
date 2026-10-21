import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/ui/term_filter.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('drops private-prefix m/u sequences (modifyOtherKeys, kitty keyboard)', () {
    final f = TermFilter();
    expect(f.add('a\x1b[>4;2mb\x1b[>1uc\x1b[<ud\x1b[?ue\x1b[>4m'), 'abcde');
    expect(f.add('\x1b[?25l\x1b[1;31mx'), '\x1b[?25l\x1b[1;31mx'); // others untouched
  });

  test('colon SGR and underline colour', () {
    expect(sgr('4:3'), '4');
    expect(sgr('4:0'), '24');
    expect(sgr('1;38:2::137:180:250;4:0'), '1;38;2;137;180;250;24');
    expect(sgr('38:5:196'), '38;5;196');
    expect(sgr('4;58;5;4;1'), '4;1'); // the 4 inside 58;5;4 is a colour, not underline
    expect(sgr('58;2;4;24;4'), '');
    expect(sgr('38;2;4;4;4;1'), '38;2;4;4;4;1');
    final f = TermFilter();
    expect(f.add('\x1b[58:2::1:2:3m'), ''); // not ESC[m (a reset)
  });

  test('a sequence split across chunks is held back', () {
    final f = TermFilter();
    expect(f.add('x\x1b[>4;'), 'x');
    expect(f.add('2my\x1b'), 'y');
    expect(f.add('[1mz'), '\x1b[1mz');
  });

  test('Claude Code start-up no longer underlines what follows', () {
    final t = Terminal()..resize(40, 3);
    t.write(TermFilter().add('\x1b[>4;2m\x1b[>1uhello'));
    expect(t.buffer.lines[0].getAttributes(0) & CellAttr.underline, 0);
    expect(t.buffer.lines[0].getAttributes(0) & CellAttr.faint, 0);
  });

  group('blend backgrounds', () {
    final f = TermFilter(blend: () => true);
    test('near-black truecolor background becomes the default', () {
      expect(f.add('\x1b[48;2;30;30;46mx'), '\x1b[49mx');
      expect(f.add('\x1b[38;2;200;0;0;48;2;0;0;0mx'), '\x1b[38;2;200;0;0;49mx');
    });
    test('lighter backgrounds, 256-colour black and colon form', () {
      expect(f.add('\x1b[48;2;80;80;80mx'), '\x1b[48;2;80;80;80mx');
      expect(f.add('\x1b[48;5;234mx'), '\x1b[49mx');
      expect(f.add('\x1b[48;5;160mx'), '\x1b[48;5;160mx');
      expect(f.add('\x1b[48:2::10:10:10mx'), '\x1b[49mx');
    });
    test('off: untouched', () {
      expect(TermFilter().add('\x1b[48;2;0;0;0mx'), '\x1b[48;2;0;0;0mx');
    });
  });
}
