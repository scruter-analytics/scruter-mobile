import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/engine.dart';
import 'package:scruter_flutter/src/screen_view.dart';

import 'support.dart';

void main() {
  ScreenView view() => ScreenView(name: 'A', session: session, analysed: true, startWall: 1762345000000, startMono: 0, number: 7);

  test('engaged time stops 60 s after the last interaction, visible time goes on', () {
    final v = view();
    v.tick(100000);
    final s = v.state(last: true, now: 100000)!;
    expect(s['dt'], 100000);
    expect(s['et'], 60000);
  });

  test('screen_end: not under 1 s unless the depth grew, the last one always once', () {
    final v = view();
    v.tick(500);
    expect(v.engagement(last: false), (500, 100));
    v.tick(900);
    expect(v.engagement(last: false), isNull);
    v.tick(2000);
    expect(v.engagement(last: false), (1500, 100));
    expect(v.engagement(last: true), isNull);
  });

  test('states are numbered 1–10, the tenth kept for the end', () {
    final v = view();
    var t = 0;
    for (var i = 0; i < 12; i++) {
      v.tap('a', 0, 'button', 1, 1, 0, 0);
      t += 10;
      v.state(last: false, now: t);
    }
    v.tap('a', 0, 'button', 1, 1, 0, 0);
    final last = v.state(last: true, now: t)!;
    expect(last['q'], 10);
    expect(last['cn'], 13);
    expect(v.state(last: true, now: t), isNull);
  });

  testWidgets('going to the background reports, a short return continues the view', (tester) async {
    final native = await startSdk(tester);
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: const Scaffold()));
    await tester.pump(const Duration(seconds: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 100));
    expect(native.ends, hasLength(1));
    expect(native.ends.single['ms'], greaterThan(2900));
    expect(native.args('flush'), hasLength(1));
    expect(native.states, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.screens, ['/', 'Other']);
    expect(native.ends.last['ms'], lessThan(3000), reason: 'the time in the background is not engaged');
    expect(native.states.last['q'], 2);
    expect(native.states.last['k'], native.states.first['k']);
  });

  testWidgets('a new session: the native side announces the screen, the old view ends with the old session', (tester) async {
    final native = await startSdk(tester);
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: const Scaffold()));
    await tester.pump(const Duration(seconds: 3));
    native.currentSession = 'aaaaaaaaaaaaaaaa';
    native.announce('/');
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(native.states.first['s'], session);
    expect(native.states.last['s'], 'aaaaaaaaaaaaaaaa');
    expect(native.states.first['k'], isNot(native.states.last['k']));
  });

  testWidgets('ignored screens: the native side says nothing, nothing is measured', (tester) async {
    final native = await startSdk(tester)..ignoredScreens = ['/'];
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: const Scaffold()));
    await tester.pump(const Duration(seconds: 3));
    expect(ScruterEngine.instance.view, isNull);
    expect(native.ends, isEmpty);
  });

  testWidgets('opt-out stops everything in Dart; opt-in waits for the native side', (tester) async {
    final native = await startSdk(tester);
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: const Scaffold(body: Text('x'))));
    await tester.pump(const Duration(seconds: 1));
    Scruter.optOut();
    await tester.tap(find.text('x'));
    await tester.pump(const Duration(seconds: 2));
    Scruter.screen('Hidden');
    await tester.pump();
    expect(native.args('optOut'), hasLength(1));
    expect(native.screens, ['/']);
    expect(native.ends, isEmpty);
    Scruter.optIn();
    native.announce('/');
    await tester.pump(const Duration(seconds: 1));
    expect(native.args('optIn'), hasLength(1));
    expect(ScruterEngine.instance.view?.name, '/');
  });

  testWidgets('events reach the native side; a value of another type is dropped', (tester) async {
    final native = await startSdk(tester);
    Scruter.track('Add to cart', props: {'color': 'blue', 'n': 2, 'ok': true, 'when': DateTime(2026)}, revenue: 49.0, currency: 'EUR');
    await tester.pump();
    final t = native.args('track').single;
    expect(t['name'], 'Add to cart');
    expect(t['props'], {'color': 'blue', 'n': 2, 'ok': true});
    expect(t['revenue'], 49.0);
    expect(t['currency'], 'EUR');
  });

  testWidgets('a debug key goes only with kDebugMode, the tests run in debug mode', (tester) async {
    final native = FakeNative()..install();
    addTearDown(() {
      ScruterEngine.resetForTests();
      native.uninstall();
    });
    await Scruter.start(appId: 'ATMONA02', debugKey: 'scr_dbg_x');
    final a = native.args('start').single;
    expect(a['debugKey'], 'scr_dbg_x');
    expect(a['appId'], 'ATMONA02');
    expect(a['version'], scruterVersion);
  });

  testWidgets('a second start is ignored', (tester) async {
    final native = await startSdk(tester);
    await Scruter.start(appId: 'OTHER');
    expect(native.args('start'), hasLength(1));
  });
}
