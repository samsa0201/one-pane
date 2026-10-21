import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fonts.dart';
import 'parts.dart';
import 'theme.dart';

/// Keys of the key row, as stored ids:
/// - named keys: esc tab ctrl alt left down up right home end pgup pgdn f1…f12 paste
/// - `^X`: the control character (^C, ^B…)
/// - `txt:<label>\u0001<text>`: a snippet, typed as is (newline = Enter)
/// - anything else: that text (`|`, `~`…)
const keysPerPage = 8, maxKeyPages = 4;

const defaultKeyPages = [
  ['esc', 'tab', 'ctrl', 'alt', 'left', 'down', 'up', 'right'],
  ['^C', '^B', 'paste', '|', '~', '/', '-', '_'],
];

/// Keys offered when adding one (minus those already on a page).
const keyPalette = [
  'esc', 'tab', 'ctrl', 'alt', 'left', 'down', 'up', 'right', 'home', 'end', 'pgup', 'pgdn', 'paste', //
  '^C', '^D', '^Z', '^R', '^L', '^A', '^E', '^B', '^W', '^U',
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
  '|', '~', '/', '-', '_', '`', '\\', ':', ';', '=', '+', '*', '&', r'$', '#', '@', '!', '?', '"', "'",
  '<', '>', '{', '}', '[', ']', '(', ')',
];

const _named = {
  'esc': 'Esc', 'tab': 'Tab', 'ctrl': 'Ctrl', 'alt': 'Alt', 'home': 'Home', 'end': 'End', //
  'pgup': 'PgUp', 'pgdn': 'PgDn', 'paste': 'Paste', 'left': 'Left', 'down': 'Down', 'up': 'Up', 'right': 'Right',
};

const arrowIcons = {
  'left': Icons.arrow_back_rounded,
  'down': Icons.arrow_downward_rounded,
  'up': Icons.arrow_upward_rounded,
  'right': Icons.arrow_forward_rounded,
};

String snippetId(String label, String text) => 'txt:$label\u0001$text';

/// (label, text) of a snippet id, else null.
(String, String)? snippetOf(String id) {
  if (!id.startsWith('txt:')) return null;
  final i = id.indexOf('\u0001');
  return i < 0 ? null : (id.substring(4, i), id.substring(i + 1));
}

String keyLabel(String id) {
  if (snippetOf(id) case (final label, _)) return label;
  if (RegExp(r'^f(1[0-2]|[1-9])$').hasMatch(id)) return id.toUpperCase();
  return _named[id] ?? id;
}

/// The control character for `^X` ids, else null.
int? ctrlByte(String id) {
  if (id.length != 2 || id[0] != '^') return null;
  final c = id.codeUnitAt(1);
  return c >= 0x40 && c <= 0x5f ? c - 0x40 : null;
}

final keyPages = ValueNotifier<List<List<String>>>(defaultKeyPages);
const _pref = 'keyRows';

Future<void> loadKeyPages() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_pref);
    if (raw == null) return;
    final v = [for (final p in jsonDecode(raw) as List) [for (final k in p as List) k as String]];
    if (v.isNotEmpty) keyPages.value = v;
  } catch (_) {}
}

void setKeyPages(List<List<String>> pages) {
  keyPages.value = pages;
  SharedPreferences.getInstance().then((p) => p.setString(_pref, jsonEncode(pages))).catchError((_) => true);
}

/// Settings › Key row: pages of up to [keysPerPage] keys; hold and drag to reorder, × to remove,
/// tap a key below to add it to the selected page.
class KeyRowScreen extends StatefulWidget {
  const KeyRowScreen({super.key});
  @override
  State<KeyRowScreen> createState() => _KeyRowScreenState();
}

class _KeyRowScreenState extends State<KeyRowScreen> {
  int _target = 0; // page that gets added keys

  /// The saved pages plus an empty one to add to (up to [maxKeyPages]); empty pages are not saved.
  List<List<String>> get _pages {
    final p = keyPages.value;
    return p.length < maxKeyPages && (p.isEmpty || p.last.isNotEmpty) ? [...p, <String>[]] : p;
  }

  void _edit(void Function(List<List<String>> p) change) {
    final p = [for (final page in _pages) [...page]];
    change(p);
    setState(() => setKeyPages([for (final page in p) if (page.isNotEmpty) page]));
  }

  void _add(String id) {
    if (_pages[_target].length >= keysPerPage) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Page ${_target + 1} is full: remove a key first'), duration: const Duration(seconds: 2)));
      return;
    }
    HapticFeedback.selectionClick();
    _edit((p) => p[_target].add(id));
  }

  Future<void> _snippet() async {
    final label = TextEditingController(), text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('Snippet key', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Tone.text)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: label,
            autofocus: true,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Label on the key'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: text,
            maxLines: 3,
            style: TextStyle(fontFamily: termFont.value),
            decoration: const InputDecoration(labelText: 'Types', hintText: 'git status⏎'),
          ),
          const SizedBox(height: 6),
          Text('A new line in the text is sent as Enter.', style: TextStyle(fontSize: 12, color: Tone.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: Tone.text))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && label.text.trim().isNotEmpty && text.text.isNotEmpty) {
      _add(snippetId(label.text.trim(), text.text));
    }
  }

  Widget _cap(String id, {double width = 40}) {
    final icon = arrowIcons[id];
    return Container(
      width: width,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Tone.raised, borderRadius: BorderRadius.circular(10)),
      child: icon != null
          ? Icon(icon, size: 18, color: Tone.text)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(keyLabel(id),
                    style: TextStyle(
                        fontFamily: termFont.value,
                        fontSize: 13,
                        color: snippetOf(id) != null ? accent : Tone.text)),
              ),
            ),
    );
  }

  Widget _page(int i) {
    final keys = _pages[i];
    final selected = i == _target;
    return GestureDetector(
      onTap: () => setState(() => _target = i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Tone.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? accent : Colors.transparent, width: 1.5),
        ),
        child: keys.isEmpty
            ? Center(child: Text('New page: select it, then tap keys below', style: TextStyle(fontSize: 13, color: Tone.muted)))
            : ReorderableListView(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: true,
                proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
                onReorderItem: (from, to) => _edit((p) => p[i].insert(to, p[i].removeAt(from))),
                children: [
                  for (var j = 0; j < keys.length; j++)
                    Padding(
                      key: ValueKey('$i:$j:${keys[j]}'),
                      padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
                      child: Stack(clipBehavior: Clip.none, children: [
                        _cap(keys[j]),
                        Positioned(
                          right: -6,
                          top: -8,
                          child: Semantics(
                            button: true,
                            label: 'Remove ${keyLabel(keys[j])}',
                            child: GestureDetector(
                              onTap: () => _edit((p) => p[i].removeAt(j)),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(color: Tone.pressed, shape: BoxShape.circle),
                                child: Icon(Icons.close_rounded, size: 13, color: Tone.text),
                              ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_target >= _pages.length) _target = _pages.length - 1; // its page emptied and went away
    final used = {for (final p in _pages) ...p};
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        const PageTitle('Key row'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text('$keysPerPage keys a page; swipe the row in the terminal for the next page. Hold and drag '
              'to reorder, × to remove. Keys below go to the selected page.',
              style: TextStyle(fontSize: 14, height: 1.45, color: Tone.muted)),
        ),
        for (var i = 0; i < _pages.length; i++) ...[
          SectionLabel('Page ${i + 1}${i == _target ? ' · adding here' : ''}'),
          _page(i),
        ],
        const SectionLabel('Add a key'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in keyPalette.where((k) => !used.contains(k)))
            Semantics(
              button: true,
              label: 'Add ${keyLabel(id)}',
              child: GestureDetector(onTap: () => _add(id), child: _cap(id, width: 52)),
            ),
          Semantics(
            button: true,
            label: 'Add a snippet key',
            child: GestureDetector(
              onTap: _snippet,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent.withValues(alpha: 0.6)),
                ),
                child: Text('Snippet…', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: accent)),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 24),
        Center(
          child: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () {
              setState(() => setKeyPages([for (final p in defaultKeyPages) [...p]]));
            },
            child: Text('Reset to default', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.muted)),
          ),
        ),
      ]),
    );
  }
}
