import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

/// The native CMP module as the channel `net.scruter/cmp` sees it: records every call, answers the snapshot it holds,
/// and tells Dart of changes as the plugins do.
class FakeCmp {
  static const channel = MethodChannel('net.scruter/cmp');

  final calls = <MethodCall>[];
  Map<String, Object?> snapshot = needs;
  bool linked = true;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (!linked) throw MissingPluginException();
      calls.add(call);
      switch (call.method) {
        case 'start':
        case 'snapshot':
          return snapshot;
        case 'showIfNeeded':
          return true;
        case 'requestTrackingIfGranted':
          return 'authorized';
      }
      return null;
    });
  }

  void uninstall() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);

  Future<void> changed(Map<String, Object?> s, bool newChoice) async {
    snapshot = s;
    final data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall('changed', <String, Object?>{'snapshot': s, 'newChoice': newChoice}));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('net.scruter/cmp', data, (_) {});
  }

  Iterable<MethodCall> named(String m) => calls.where((c) => c.method == m);
}

const choice = <String, Object?>{
  'consentId': 'cns_0123456789abcdef0123',
  'decidedAt': 1790000000000,
  'granted': ['analytics', 'necessary'],
  'denied': ['advertising'],
};
const ready = <String, Object?>{
  'state': 'ready',
  'consentId': 'cns_0123456789abcdef0123',
  'choice': choice,
  'granted': ['analytics', 'necessary'],
  'signals': {'analytics_storage': 'granted', 'ad_storage': 'denied', 'security_storage': 'granted'},
};
const needs = <String, Object?>{
  'state': 'needsDecision',
  'granted': ['necessary'],
  'signals': {'security_storage': 'granted'},
};

Map<String, Object?> later(int at, List<String> granted) => {
      ...ready,
      'choice': {...choice, 'decidedAt': at, 'granted': granted},
      'granted': granted,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCmp native;

  setUp(() {
    ScruterCMP.resetForTest();
    native = FakeCmp()..install();
  });
  tearDown(() => native.uninstall());

  group('start', () {
    test('forwards the options once and names the wrapper', () async {
      ScruterCMP.forceShow = true;
      ScruterCMP.setLanguage('DE');
      await ScruterCMP.start(appId: 'ATMONA02', presentation: ScruterPresentation.manual, endpoint: 'http://127.0.0.1:8765');
      await ScruterCMP.start(appId: 'ATMONA03');
      expect(native.named('start').map((c) => c.arguments), [
        {
          'appId': 'ATMONA02',
          'manual': true,
          'endpoint': 'http://127.0.0.1:8765',
          'version': scruterVersion,
          'forceShow': true,
          'debug': false,
          'language': 'de',
        }
      ]);
      expect(native.named('setForceShow'), isEmpty);
      expect(native.named('setLanguage'), isEmpty);
    });

    test('answers from the stored choice on the next line', () async {
      native.snapshot = ready;
      await ScruterCMP.start(appId: 'ATMONA02');
      expect(ScruterCMP.isGranted('analytics'), isTrue);
      expect(ScruterCMP.isGranted('advertising'), isFalse);
      expect(ScruterCMP.isGranted('necessary'), isTrue);
      expect(ScruterCMP.state, ScruterConsentState.ready);
      expect(ScruterCMP.consentId, 'cns_0123456789abcdef0123');
      final c = ScruterCMP.choice!;
      expect(c.decidedAt, DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true));
      expect(c.granted, ['analytics', 'necessary']);
      expect(c.denied, ['advertising']);
      expect(c.isGranted('necessary'), isTrue);
      expect(ScruterCMP.consentModeSignals()['analytics_storage'], ScruterConsentStatus.granted);
      expect(ScruterCMP.consentModeSignals()['ad_user_data'], ScruterConsentStatus.denied);
    });

    test('says so and grants nothing when the native module is not in the app', () async {
      native.linked = false;
      await ScruterCMP.start(appId: 'ATMONA02');
      expect(ScruterCMP.isGranted('analytics'), isFalse);
      expect(ScruterCMP.state, ScruterConsentState.unavailable);
      expect(await ScruterCMP.showIfNeeded(), isFalse);
    });
  });

  test('before start: nothing granted, nothing native', () async {
    await ScruterCMP.showPreferences();
    await ScruterCMP.debugReset();
    expect(ScruterCMP.isGranted('analytics'), isFalse);
    expect(ScruterCMP.isGranted('necessary'), isFalse);
    expect(ScruterCMP.state, ScruterConsentState.unavailable);
    expect(ScruterCMP.choice, isNull);
    expect(ScruterCMP.consentId, isNull);
    expect(ScruterCMP.consentModeSignals(), {
      for (final k in scruterConsentSignals)
        k: k == 'security_storage' ? ScruterConsentStatus.granted : ScruterConsentStatus.denied,
    });
    expect(await ScruterCMP.requestTrackingIfGranted(), ScruterTrackingStatus.notDetermined);
    expect(native.calls, isEmpty);
  });

  test('forwards the settings entry, the manual presentation, ATT, the language, debug and the reset', () async {
    await ScruterCMP.start(appId: 'ATMONA02', presentation: ScruterPresentation.manual);
    await ScruterCMP.showPreferences();
    expect(await ScruterCMP.showIfNeeded(), isTrue);
    expect(await ScruterCMP.requestTrackingIfGranted(), ScruterTrackingStatus.authorized);
    ScruterCMP.setLanguage('fr');
    ScruterCMP.setLanguage(null);
    ScruterCMP.debug = true;
    ScruterCMP.forceShow = true;
    await ScruterCMP.debugReset();
    await Future<void>.delayed(Duration.zero);
    expect(native.named('showPreferences'), hasLength(1));
    expect(native.named('showIfNeeded'), hasLength(1));
    expect(native.named('setLanguage').map((c) => c.arguments), [
      {'language': 'fr'},
      {'language': null},
    ]);
    expect(native.named('setDebug').single.arguments, {'on': true});
    expect(native.named('setForceShow').single.arguments, {'on': true});
    expect(native.named('debugReset'), hasLength(1));
  });

  group('whenReady, onChange and choices', () {
    test('a first launch: whenReady at the decision, onChange for every later change only', () async {
      final readyIds = <String>[];
      final changed = <List<String>>[];
      final streamed = <ScruterChoice>[];
      ScruterCMP.whenReady((c) => readyIds.add(c.consentId));
      ScruterCMP.onChange((c) => changed.add(c.granted));
      final sub = ScruterCMP.choices.listen(streamed.add);
      await ScruterCMP.start(appId: 'ATMONA02');
      await native.changed(ready, true);
      expect(readyIds, ['cns_0123456789abcdef0123']);
      expect(changed, isEmpty);
      // The same choice told again: nothing.
      await native.changed(ready, true);
      expect(changed, isEmpty);
      await native.changed(later(1790000060000, ['necessary']), true);
      expect(changed, [
        ['necessary']
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(streamed.map((c) => c.granted), [
        ['analytics', 'necessary'],
        ['necessary'],
      ]);
      var lateCalls = 0;
      ScruterCMP.whenReady((_) => lateCalls++);
      expect(lateCalls, 0);
      await Future<void>.delayed(Duration.zero);
      expect(lateCalls, 1);
      await sub.cancel();
    });

    test('a returning visitor: whenReady at once, the stream starts with the choice, no change told again', () async {
      native.snapshot = ready;
      await ScruterCMP.start(appId: 'ATMONA02');
      var readyCalls = 0;
      var changes = 0;
      ScruterCMP.whenReady((_) => readyCalls++);
      ScruterCMP.onChange((_) => changes++);
      final first = await ScruterCMP.choices.first;
      expect(first.consentId, 'cns_0123456789abcdef0123');
      await native.changed(ready, true);
      await Future<void>.delayed(Duration.zero);
      expect(readyCalls, 1);
      expect(changes, 0);
    });

    test('a re-ask then its answer, a reset then a new decision: changes', () async {
      native.snapshot = ready;
      await ScruterCMP.start(appId: 'ATMONA02');
      var changes = 0;
      ScruterCMP.onChange((_) => changes++);
      await native.changed({...needs, 'consentId': 'cns_0123456789abcdef0123', 'granted': ['analytics', 'necessary']}, false);
      expect(ScruterCMP.choice, isNull);
      expect(ScruterCMP.isGranted('analytics'), isTrue, reason: 'the unchanged purpose keeps its answer');
      expect(changes, 0);
      await native.changed(later(1790000001000, ['analytics', 'necessary']), true);
      expect(changes, 1);
      await native.changed(needs, false);
      await native.changed({...ready, 'choice': {...choice, 'consentId': 'cns_ffffffffffffffffffff'}}, true);
      expect(changes, 2);
    });

    test('cancels a callback', () async {
      var readyCalls = 0;
      var changes = 0;
      ScruterCMP.whenReady((_) => readyCalls++).cancel();
      final sub = ScruterCMP.onChange((_) => changes++);
      await ScruterCMP.start(appId: 'ATMONA02');
      await native.changed(ready, true);
      sub.cancel();
      await native.changed(later(5, ['necessary']), true);
      expect(readyCalls, 0);
      expect(changes, 0);
    });

    test('a hot restart: a new isolate starts nothing new and hears each change once', () async {
      await ScruterCMP.start(appId: 'ATMONA02');
      await native.changed(ready, true);
      ScruterCMP.resetForTest();
      var changes = 0;
      ScruterCMP.onChange((_) => changes++);
      await ScruterCMP.start(appId: 'ATMONA02');
      expect(native.named('start'), hasLength(2), reason: 'the native module ignores the second start');
      expect(ScruterCMP.choice?.consentId, 'cns_0123456789abcdef0123');
      await native.changed(later(9, ['necessary']), true);
      expect(changes, 1);
    });
  });
}
