import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/engine.dart';

const session = '9c1b2d3e4f5a6b7c';

/// The native SDK as the channel sees it: records every call and announces screen views, as the real ones do.
class FakeNative {
  FakeNative({this.analysed = true, this.capture = false});

  static const _channel = MethodChannel('net.scruter/flutter');

  final List<MethodCall> calls = [];
  bool analysed;
  bool capture;
  List<String> ignoredScreens = [];
  String currentSession = session;
  List<Map<String, Object?>> strips = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'screen') {
        final name = (call.arguments as Map)['name'] as String;
        if (!ignoredScreens.contains(name)) announce(name);
      }
      if (call.method == 'imageStrip') strips.add(Map<String, Object?>.from(call.arguments as Map));
      return null;
    });
  }

  void announce(String name) {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('screenStarted', <String, Object?>{
      'session': currentSession,
      'name': name,
      'startMs': 1762345000000,
      'analysed': analysed,
      'capture': capture,
      'maxBytes': 2000000,
      'maxHeight': 10000,
    }));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('net.scruter/flutter', data, (_) {});
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  }

  Iterable<Map<dynamic, dynamic>> args(String method) =>
      calls.where((c) => c.method == method).map((c) => (c.arguments as Map?) ?? const {});

  List<String> get screens => args('screen').map((a) => a['name'] as String).toList();

  /// Analysed states, newest last.
  List<Map<String, dynamic>> get states =>
      args('analysed').map((a) => jsonDecode(a['json'] as String) as Map<String, dynamic>).toList();

  /// Every tap of every state.
  List<List<dynamic>> get taps => states.expand((s) => (s['c'] as List? ?? const []).cast<List<dynamic>>()).toList();

  List<Map<dynamic, dynamic>> get ends => args('screenEnd').toList();
}

/// Starts the SDK against [FakeNative], with the test binding's clock.
Future<FakeNative> startSdk(WidgetTester tester, {bool analysed = true, bool capture = false, bool debug = false}) async {
  final native = FakeNative(analysed: analysed, capture: capture)..install();
  ScruterEngine.testClock = () => tester.binding.clock.now().millisecondsSinceEpoch;
  ScruterEngine.measureRetries = 0;
  await Scruter.start(appId: 'ATMONA02', debug: debug);
  addTearDown(() {
    ScruterEngine.resetForTests();
    ScruterEngine.testClock = null;
    ScruterEngine.measureRetries = 3;
    native.uninstall();
  });
  return native;
}

/// Ends the current screen view: what it held reaches the native side.
Future<void> leave(WidgetTester tester, [String to = 'Other']) async {
  Scruter.screen(to);
  await tester.pump(const Duration(seconds: 1));
}

/// Writes a payload for the protocol kit's validator (`scripts/conformance.sh`).
void conformance(String schema, String name, Map<String, Object?> json) {
  final dir = Directory('build/conformance')..createSync(recursive: true);
  File('${dir.path}/$schema--$name.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// [states] and [events] in a minimal batch, to validate them against the batch schema.
Map<String, Object?> batchOf({
  List<Map<String, dynamic>> states = const [],
  List<Map<String, Object?>> events = const [],
  List<Map<String, Object?>> crashes = const [],
}) =>
    {
      'v': 1,
      'a': 'ATMONA02',
      'b': '0' * 32,
      't': 1762345678901,
      'sdk': 'flutter/1.1.0',
      's': [
        {
          'id': session,
          'd': '0' * 32,
          'q': 1,
          'st': 1762345000000,
          'p': 'android',
          'av': '1.0.0',
          'bk': 'release',
          'os': '15',
          'm': 'Google Pixel 8',
          'f': 'phone',
          'c': {'sv': 1, 'ev': 0, 'dur': 3, 'cr': 0, 'anr': 0, 'last': 1762345000000},
        },
      ],
      if (events.isNotEmpty) 'e': events,
      if (states.isNotEmpty) 'x': states,
      if (crashes.isNotEmpty) 'cr': crashes,
    };
