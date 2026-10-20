import 'package:flutter/services.dart';

/// Home-screen widget (Android): which host it asked to open, and refreshing its list.
/// A host id of '' means "show the host list". No-ops where the platform side is missing (tests).
class QuickAccess {
  static const _channel = MethodChannel('tmux_pocket/launch');

  /// The host the app was started for, once.
  static Future<String?> initialHost() async {
    try {
      return await _channel.invokeMethod<String>('initialHost');
    } on MissingPluginException {
      return null;
    }
  }

  /// [onHost] runs when the widget is tapped while the app is running.
  static void listen(void Function(String hostId) onHost) => _channel.setMethodCallHandler((call) async {
        if (call.method == 'launch') onHost(call.arguments as String);
      });

  /// Hosts or a remembered place changed.
  static Future<void> refresh() async {
    try {
      await _channel.invokeMethod('refresh');
    } on MissingPluginException {
      // no widget support on this platform
    }
  }
}
