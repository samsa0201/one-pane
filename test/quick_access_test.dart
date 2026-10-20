import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/quick_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tmux_pocket/launch');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('no platform side: no host, refresh is a no-op', () async {
    expect(await QuickAccess.initialHost(), isNull);
    await QuickAccess.refresh();
  });

  test('initial host and refresh go to Android', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'initialHost' ? 'h1' : null;
    });
    expect(await QuickAccess.initialHost(), 'h1');
    await QuickAccess.refresh();
    expect(calls, ['initialHost', 'refresh']);
  });

  test('a widget tap while running reaches the listener', () async {
    String? got;
    QuickAccess.listen((id) => got = id);
    await messenger.handlePlatformMessage(
        channel.name, channel.codec.encodeMethodCall(const MethodCall('launch', 'h2')), (_) {});
    expect(got, 'h2');
  });
}
