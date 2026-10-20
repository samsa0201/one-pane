import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ssh/connection.dart';
import 'ui/fonts.dart';
import 'ui/glass.dart';
import 'ui/hosts_screen.dart';

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
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'tmux pocket',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF4FC3F7),
        // Screens are see-through: the ambient (and glass over it) is the background everywhere.
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent),
        bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
        listTileTheme: const ListTileThemeData(selectedTileColor: Color(0x224FC3F7)),
      ),
      builder: (context, child) => Stack(fit: StackFit.expand, children: [const Ambient(), child!]),
      home: const HostsScreen(),
    );
  }
}
