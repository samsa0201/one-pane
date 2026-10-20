import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tmux_pocket/ui/glass.dart';

void main() {
  testWidgets('glass effects off: same panel, no backdrop blur; the choice is saved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => glassEffects.value = true);
    await tester.pumpWidget(const MaterialApp(home: Center(child: Glass(child: Text('x')))));
    expect(find.byType(BackdropFilter), findsOneWidget);
    setGlassEffects(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('x'), findsOneWidget);
    await tester.pump();
    expect((await SharedPreferences.getInstance()).getBool('glassEffects'), isFalse);
    glassEffects.value = true;
    await loadGlassPref();
    expect(glassEffects.value, isFalse);
  });
}
