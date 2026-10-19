import 'package:flutter/material.dart';

import 'ui/hosts_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'tmux pocket',
      theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF4FC3F7)),
      home: const HostsScreen(),
    );
  }
}
