import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native SDK, through the plugin's channel: it owns sessions, the queue, the configuration, the network, native
/// crashes, the install referrer, openings and team-phone registration (docs/MOBILE.md §17).
class ScruterBridge {
  ScruterBridge(this._onScreen) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'screenStarted') _onScreen(NativeScreen.from(call.arguments as Map<Object?, Object?>));
    });
  }

  static const _channel = MethodChannel('net.scruter/flutter');

  final void Function(NativeScreen) _onScreen;

  /// The calls never throw: the SDK must not stand in the app's way (an unsupported platform has no plugin).
  Future<T?> call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('Scruter: $method failed: ${e.code}');
      return null;
    }
  }

  void detach() => _channel.setMethodCallHandler(null);
}

/// A screen view that began, as the native SDK announces it.
class NativeScreen {
  const NativeScreen({
    required this.session,
    required this.name,
    required this.startMs,
    required this.analysed,
    required this.capture,
    required this.maxBytes,
    required this.maxHeight,
  });

  factory NativeScreen.from(Map<Object?, Object?> m) => NativeScreen(
        session: m['session']! as String,
        name: m['name']! as String,
        startMs: (m['startMs']! as num).toInt(),
        analysed: m['analysed'] == true,
        capture: m['capture'] == true,
        maxBytes: (m['maxBytes'] as num?)?.toInt() ?? 0,
        maxHeight: (m['maxHeight'] as num?)?.toInt() ?? 0,
      );

  final String session;
  final String name;
  final int startMs;

  /// The session is in the Advanced analytics sample.
  final bool analysed;

  /// This team phone is to take the screen's image.
  final bool capture;
  final int maxBytes;
  final int maxHeight;
}
