import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fonts.dart';
import 'glass.dart';
import 'keys.dart';
import 'parts.dart';
import 'security_screen.dart';

/// A setting kept in shared preferences, observable by the screens that use it.
class Pref<T> extends ValueNotifier<T> {
  final String key;
  Pref(this.key, super.value);

  Future<void> load(SharedPreferences p) async {
    final v = p.get(key);
    if (v is T) value = v;
  }

  void set(T v) {
    value = v;
    SharedPreferences.getInstance().then((p) => switch (v) {
          final bool b => p.setBool(key, b),
          final double d => p.setDouble(key, d),
          _ => Future.value(true),
        }).catchError((_) => true);
  }
}

final joystickOn = Pref<bool>('joystick', true);

/// Phone mode: tmux sized to this screen, the shown pane zoomed. Off: desktop size, font scaled.
final phoneMode = Pref<bool>('phoneMode', true);
final followActive = Pref<bool>('follow', true);
final termFontSize = Pref<double>('fontSize', 13);

Future<void> loadSettings() async {
  try {
    final p = await SharedPreferences.getInstance();
    for (final s in <Pref<Object>>[joystickOn, phoneMode, followActive, termFontSize]) {
      await s.load(p);
    }
  } catch (_) {}
}

void openSettings(BuildContext context) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(toolbarHeight: 40),
        body: ListenableBuilder(
          listenable: Listenable.merge(
              [termPalette, termFont, termFontSize, glassEffects, joystickOn, phoneMode, followActive, keyPages]),
          builder: (context, _) {
            final t = termPalette.value;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
              const PageTitle('Settings'),
              const SectionLabel('Look'),
              Group(children: [
                NavRow(
                  title: 'Theme',
                  value: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final c in [t.ansi[1], t.ansi[2], t.ansi[3], t.ansi[4]])
                      Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(t.name, style: TextStyle(fontSize: 14, color: Tone.muted)),
                  ]),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ThemeScreen())),
                ),
                NavRow(
                  title: 'Terminal font',
                  value: Text(termFonts.firstWhere((f) => f.family == termFont.value).name,
                      style: TextStyle(fontFamily: termFont.value, fontSize: 13, color: Tone.muted)),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FontScreen())),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('Terminal text size', style: TextStyle(fontSize: 15, color: Tone.text))),
                      Text(termFontSize.value.toStringAsFixed(termFontSize.value % 1 == 0 ? 0 : 1),
                          style: TextStyle(fontFamily: termFont.value, fontSize: 13, color: Tone.muted)),
                      const SizedBox(width: 8),
                    ]),
                    Slider(
                      value: termFontSize.value.clamp(8, 24),
                      min: 8,
                      max: 24,
                      divisions: 32,
                      label: '${termFontSize.value}',
                      onChanged: termFontSize.set,
                    ),
                  ]),
                ),
                SwitchRow(
                  title: 'Glass effects',
                  subtitle: 'Frosted sheets. Off saves battery',
                  value: glassEffects.value,
                  onChanged: setGlassEffects,
                ),
              ]),
              const SectionLabel('Keys and moving'),
              Group(children: [
                NavRow(
                  title: 'Key row',
                  value: Text(
                      '${keyPages.value.where((p) => p.isNotEmpty).length} pages',
                      style: TextStyle(fontSize: 14, color: Tone.muted)),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const KeyRowScreen())),
                ),
                SwitchRow(
                  title: 'Joystick',
                  subtitle: 'Floating stick for panes, windows and sessions',
                  value: joystickOn.value,
                  onChanged: joystickOn.set,
                ),
                SwitchRow(
                  title: 'Fit tmux to this phone',
                  subtitle: 'Off: keep the desktop size and scale the text down',
                  value: phoneMode.value,
                  onChanged: phoneMode.set,
                ),
                SwitchRow(
                  title: 'Follow other clients',
                  subtitle: 'Jump when another client changes pane',
                  value: followActive.value,
                  onChanged: followActive.set,
                ),
              ]),
              const SectionLabel('Security'),
              Group(children: [
                NavRow(
                  title: 'Keys on this phone',
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const KeysScreen())),
                ),
                NavRow(
                  title: 'Known hosts',
                  onTap: () =>
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const KnownHostsScreen())),
                ),
              ]),
              const SectionLabel('About'),
              Group(children: [
                NavRow(
                  title: 'Open-source licenses',
                  onTap: () => showLicensePage(context: context, applicationName: 'One Pane'),
                ),
              ]),
            ]);
          },
        ),
      );
}

/// Theme picker: a sample of output in the theme, the presets as cards in their own colours.
class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(toolbarHeight: 40),
        body: ListenableBuilder(
          listenable: Listenable.merge([termPalette, blendBackgrounds]),
          builder: (context, _) {
            final t = termPalette.value, a = t.ansi;
            final mono = TextStyle(fontFamily: termFont.value, fontSize: 12.5, height: 1.5, color: t.fg);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
              const PageTitle('Theme'),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                child: Text('Colours for the terminal. The bar and sheets take their tone from it.',
                    style: TextStyle(fontSize: 14, height: 1.4, color: Tone.muted)),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Tone.line),
                ),
                child: Text.rich(
                  TextSpan(style: mono, children: [
                    TextSpan(text: '~/dev/api', style: TextStyle(color: a[4])),
                    const TextSpan(text: ' on '),
                    TextSpan(text: 'main\n', style: TextStyle(color: a[5])),
                    TextSpan(text: '❯ ', style: TextStyle(color: a[2])),
                    const TextSpan(text: 'pnpm test\n'),
                    TextSpan(text: ' PASS ', style: TextStyle(color: t.bg, backgroundColor: a[2])),
                    const TextSpan(text: ' src/auth.test.ts\n'),
                    TextSpan(text: ' FAIL ', style: TextStyle(color: t.bg, backgroundColor: a[1])),
                    const TextSpan(text: ' src/billing.test.ts\n'),
                    TextSpan(text: 'warn', style: TextStyle(color: a[3])),
                    const TextSpan(text: ' 1 retry budget spent'),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.4,
                children: [for (final p in palettes) _ThemeCard(p, selected: p.name == t.name)],
              ),
              const SizedBox(height: 14),
              Group(children: [
                SwitchRow(
                  title: 'Blend app backgrounds',
                  subtitle: 'Near-black backgrounds from nvim and other apps use the theme’s',
                  value: blendBackgrounds.value,
                  onChanged: setBlendBackgrounds,
                ),
              ]),
            ]);
          },
        ),
      );
}

class _ThemeCard extends StatelessWidget {
  final TermPalette p;
  final bool selected;
  const _ThemeCard(this.p, {required this.selected});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '${p.name} theme',
        child: GestureDetector(
          onTap: () => setPalette(p),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: p.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: selected ? p.accent : p.fg.withValues(alpha: 0.12), width: selected ? 2 : 1),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.fg)),
              const SizedBox(height: 6),
              Row(children: [
                for (final i in const [1, 2, 3, 4, 5])
                  Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(color: p.ansi[i], shape: BoxShape.circle)),
              ]),
            ]),
          ),
        ),
      );
}

/// Nerd Fonts: Hack is bundled, the others download once (about 2–5 MB each) when picked.
class FontScreen extends StatefulWidget {
  const FontScreen({super.key});
  @override
  State<FontScreen> createState() => _FontScreenState();
}

class _FontScreenState extends State<FontScreen> {
  String? _busy;
  double _progress = 0;

  Future<void> _pick(TermFont f) async {
    setState(() {
      _busy = f.family;
      _progress = 0;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await useFont(f, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${f.name}: $e')));
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(toolbarHeight: 40),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          const PageTitle('Terminal font'),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text('Nerd Font builds, so prompt and editor icons show. Hack is built in; the others '
                'download once.', style: TextStyle(fontSize: 14, height: 1.4, color: Tone.muted)),
          ),
          Group(children: [
            for (final f in termFonts)
              FutureBuilder<bool>(
                future: fontReady(f),
                builder: (ctx, ready) {
                  final on = f.family == termFont.value;
                  return ListTile(
                    minVerticalPadding: 12,
                    title: Text(f.name,
                        style: TextStyle(
                            fontFamily: ready.data == true ? f.family : null, fontSize: 15, color: on ? accent : Tone.text)),
                    subtitle: Text(f.bundled ? 'built in' : (ready.data == true ? 'downloaded' : 'tap to download'),
                        style: TextStyle(fontSize: 13, color: Tone.muted)),
                    trailing: _busy == f.family
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(value: _progress > 0 ? _progress : null, strokeWidth: 2))
                        : on
                            ? Icon(Icons.check_rounded, color: accent)
                            : ready.data == false
                                ? Icon(Icons.download_rounded, color: Tone.muted)
                                : null,
                    onTap: _busy != null ? null : () => _pick(f),
                  );
                },
              ),
          ]),
        ]),
      );
}
