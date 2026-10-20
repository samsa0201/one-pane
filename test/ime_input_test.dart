import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/ui/ime_input.dart';

void main() {
  test('imeDiff', () {
    expect(imeDiff('  a', '  â'), (1, 'â'));
    expect(imeDiff('  viet', '  việt'), (2, 'ệt'));
    expect(imeDiff('  ab', '  ab c'), (0, ' c'));
    expect(imeDiff('  ', ' '), (1, ''));
    expect(imeDiff('  😀', '  😁'), (1, '😁')); // surrogate pair kept whole
  });

  testWidgets('Telex rewrites are sent as backspace + new text', (tester) async {
    final out = StringBuffer();
    final focus = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: ImeInput(
        focusNode: focus,
        onInsert: out.write,
        onBackspace: () => out.write('<BS>'),
        onEnter: () => out.write('<CR>'),
        child: Focus(focusNode: focus, child: const SizedBox.expand()),
      ),
    ));
    // focus alone (xterm focuses on every touch-down) does not open the keyboard, nor do two fingers
    focus.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    final a = await tester.startGesture(const Offset(100, 100), pointer: 1);
    final b = await tester.startGesture(const Offset(200, 100), pointer: 2);
    await a.up();
    await b.up();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byType(SizedBox));
    expect(tester.testTextInput.isVisible, isTrue);

    void ime(String text, {TextRange composing = TextRange.empty}) => tester.testTextInput.updateEditingValue(
        TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length), composing: composing));
    // Laban/Telex style: committed text is rewritten in place.
    ime('  v');
    ime('  vi');
    ime('  vie');
    ime('  viê');
    ime('  viêt');
    ime('  việt');
    // Gboard style: composing region.
    ime('  việt n', composing: const TextRange(start: 7, end: 8));
    ime('  việt na', composing: const TextRange(start: 7, end: 9));
    ime('  việt nam', composing: const TextRange(start: 7, end: 10));
    ime('  việt nam');
    ime('  việt na'); // backspace
    ime('  việt na\n');
    expect(out.toString(), 'vie<BS>êt<BS><BS>ệt nam<BS><CR>');
    // after Enter the buffer starts over
    ime('  x');
    expect(out.toString(), endsWith('<CR>x'));

    // keyboard hidden by the user (back key), focus kept: a tap shows it again
    tester.testTextInput.hide();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byType(SizedBox));
    expect(tester.testTextInput.isVisible, isTrue);
  });
}
