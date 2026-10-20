import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Soft-keyboard input for a terminal that works with IMEs that rewrite text already typed
/// (Vietnamese Telex/VNI: "a" + "a" → "â", Gboard composing "viet" → "việt").
///
/// xterm's own input resets the editing buffer after every commit and only sends what was appended,
/// so a rewrite of an earlier character is lost. Here the buffer is kept (it mirrors what was sent),
/// and every change is sent as a diff: backspaces for the removed tail, then the new tail.
class ImeInput extends StatefulWidget {
  final FocusNode focusNode;
  final void Function(String text) onInsert;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;
  final Widget child;
  const ImeInput({
    super.key,
    required this.focusNode,
    required this.onInsert,
    required this.onBackspace,
    required this.onEnter,
    required this.child,
  });
  @override
  State<ImeInput> createState() => ImeInputState();
}

/// Two spaces in front so a backspace on an "empty" line is still an edit the IME reports.
const _base = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));

/// Edit turning [old] into [now]: (characters to delete from the end of old, text to append).
(int, String) imeDiff(String old, String now) {
  var p = 0;
  while (p < old.length && p < now.length && old.codeUnitAt(p) == now.codeUnitAt(p)) {
    p++;
  }
  // don't split a surrogate pair
  if (p > 0 && p < old.length && (old.codeUnitAt(p) & 0xFC00) == 0xDC00) p--;
  return (old.substring(p).runes.length, now.substring(p));
}

class ImeInputState extends State<ImeInput> with TextInputClient {
  TextInputConnection? _conn;
  var _value = _base;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(ImeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    _conn?.close();
    super.dispose();
  }

  // Focus alone does not open the keyboard: xterm takes focus on every touch-down (swipes, pinches).
  void _focusChanged() {
    if (!widget.focusNode.hasFocus) _close();
  }

  /// Opens (or re-shows after the user hid it) the soft keyboard.
  void show() {
    if (_conn?.attached ?? false) {
      _conn!.show();
      return;
    }
    _conn = TextInput.attach(
        this,
        const TextInputConfiguration(
          autocorrect: false,
          // Gboard turns Telex/VNI off in fields without suggestions; autocorrect stays off.
          enableSuggestions: true,
          enableIMEPersonalizedLearning: false,
          inputAction: TextInputAction.newline,
        ))
      ..show();
    _reset();
  }

  void _close() {
    _conn?.close();
    _conn = null;
  }

  void _reset() {
    _value = _base;
    _conn?.setEditingState(_base);
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  void updateEditingValue(TextEditingValue value) {
    final (del, ins) = imeDiff(_value.text, value.text);
    _value = value;
    for (var i = 0; i < del; i++) {
      widget.onBackspace();
    }
    final lines = ins.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) widget.onEnter();
      if (lines[i].isNotEmpty) widget.onInsert(lines[i]);
    }
    // Start over after Enter, or once the buffer gets long (only between words, so the IME
    // can still rewrite the word being typed).
    if (lines.length > 1 || (value.text.length > 200 && value.composing.isCollapsed && ins.endsWith(' '))) {
      _reset();
    }
  }

  @override
  void performAction(TextInputAction action) {
    widget.onEnter();
    _reset();
  }

  @override
  void connectionClosed() => _conn = null;

  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}

  Offset? _downAt;
  DateTime _downTime = DateTime(0);
  int _pointers = 0;
  bool _multi = false;

  // Only a quick one-finger tap opens the keyboard (or brings it back after back hid it).
  // Pointer level: TerminalView's own recognizers win the gesture arena.
  void _up(PointerEvent e) {
    _pointers = (_pointers - 1).clamp(0, 10);
    final d = _downAt;
    if (_pointers > 0) return;
    final tap = !_multi &&
        d != null &&
        (e.position - d).distance < 16 &&
        DateTime.now().difference(_downTime).inMilliseconds < 300;
    _downAt = null;
    _multi = false;
    if (tap && e is PointerUpEvent) {
      widget.focusNode.requestFocus();
      show();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (++_pointers > 1) _multi = true;
          _downAt ??= e.position;
          if (_pointers == 1) _downTime = DateTime.now();
        },
        onPointerUp: _up,
        onPointerCancel: _up,
        child: widget.child,
      );
}
