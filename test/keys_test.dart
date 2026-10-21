import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/ui/keys.dart';

void main() {
  test('key ids', () {
    expect(keyLabel('esc'), 'Esc');
    expect(keyLabel('f11'), 'F11');
    expect(keyLabel('|'), '|');
    expect(ctrlByte('^C'), 3);
    expect(ctrlByte('^['), 0x1b);
    expect(ctrlByte('^c'), isNull);
    final id = snippetId('gs', 'git status\n');
    expect(snippetOf(id), ('gs', 'git status\n'));
    expect(keyLabel(id), 'gs');
    expect(snippetOf('paste'), isNull);
  });
}
