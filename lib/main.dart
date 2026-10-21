import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ssh/connection.dart';
import 'ui/fonts.dart';
import 'ui/glass.dart';
import 'ui/hosts_screen.dart';
import 'ui/keys.dart';
import 'ui/settings_screen.dart';

// Debug-only: `--dart-define=POCKET_SEED=<base64 json of HostConfig + "key">` adds a host on first run,
// so on-device testing does not need typing a PEM key.
const _seed = String.fromEnvironment('POCKET_SEED');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode && _seed.isNotEmpty) {
    final store = HostStore();
    final j = jsonDecode(utf8.decode(base64.decode(_seed))) as Map<String, dynamic>;
    if (!(await store.load()).any((h) => h.id == j['id'])) {
      await store.save(HostConfig.fromJson(j)..privateKeyPem = j['key'] as String?);
    }
  }
  await loadGlassPref();
  await loadFontPref();
  await loadThemePrefs();
  await loadSettings();
  await loadKeyPages();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<TermPalette>(
        valueListenable: termPalette,
        builder: (context, t, _) {
          final light = t.light;
          final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: light ? Brightness.light : Brightness.dark)
              .copyWith(
            primary: accent,
            onPrimary: Tone.onAccent,
            surface: Tone.surface,
            onSurface: Tone.text,
            onSurfaceVariant: Tone.muted,
            surfaceContainerHigh: Tone.raised,
            surfaceContainerHighest: Tone.raised,
            outlineVariant: Tone.line,
            error: Tone.danger,
          );
          final icons = light ? Brightness.dark : Brightness.light;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: icons,
              statusBarBrightness: light ? Brightness.light : Brightness.dark,
              systemNavigationBarColor: Tone.surface,
              systemNavigationBarIconBrightness: icons,
            ),
            child: MaterialApp(
              title: 'One Pane',
              theme: ThemeData(
                colorScheme: scheme,
                scaffoldBackgroundColor: Tone.ground,
                canvasColor: Tone.ground,
                dividerColor: Tone.line,
                appBarTheme: AppBarTheme(
                  backgroundColor: Tone.ground,
                  surfaceTintColor: Colors.transparent,
                  foregroundColor: Tone.text,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                ),
                snackBarTheme: SnackBarThemeData(
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: Tone.pressed,
                  contentTextStyle: TextStyle(color: Tone.text),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                listTileTheme: ListTileThemeData(
                  iconColor: Tone.muted,
                  textColor: Tone.text,
                  subtitleTextStyle: TextStyle(fontSize: 13, color: Tone.muted),
                  selectedColor: accent,
                  selectedTileColor: accent.withValues(alpha: 0.08),
                ),
                switchTheme: SwitchThemeData(
                  trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                  thumbColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected) ? Tone.onAccent : Tone.muted),
                  trackColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected) ? accent : Tone.raised),
                ),
                inputDecorationTheme: InputDecorationTheme(
                  filled: true,
                  fillColor: Tone.raised,
                  labelStyle: TextStyle(color: Tone.muted),
                  floatingLabelStyle: TextStyle(color: accent),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: accent, width: 1.5)),
                  errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Tone.danger, width: 1.5)),
                ),
                dialogTheme: DialogThemeData(backgroundColor: Tone.raised),
                popupMenuTheme: PopupMenuThemeData(color: Tone.raised),
                sliderTheme: SliderThemeData(activeTrackColor: accent, thumbColor: accent, inactiveTrackColor: Tone.raised),
                progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
              ),
              home: const HostsScreen(),
            ),
          );
        },
      );
}
