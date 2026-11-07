import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/engine.dart';

import 'support.dart';

void main() {
  Future<FakeNative> screen(WidgetTester tester, Widget body, {bool analysed = true}) async {
    final native = await startSdk(tester, analysed: analysed);
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: Scaffold(body: body)));
    await tester.pump(const Duration(milliseconds: 100));
    return native;
  }

  Finder scrollable() => find.byType(Scrollable).first;

  testWidgets('a screen that does not scroll: depth 100, one band of the whole', (tester) async {
    final native = await screen(tester, const Text('x'));
    await tester.tap(find.text('x'));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.ends.single['depth'], 100);
    final s = native.states.last;
    expect(s['sd'], 100);
    expect(s['at'], hasLength(50));
    expect((s['at'] as List).toSet(), hasLength(1));
  });

  testWidgets('scroll depth on a long screen, rounded to 5, the deepest kept', (tester) async {
    final native = await screen(tester, SingleChildScrollView(child: Container(height: 6000, color: Colors.red)));
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(scrollable(), const Offset(0, -1800));
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(scrollable(), const Offset(0, 900));
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final s = native.states.last;
    // A 600-point screen: (1800 + 600) / 6000 = 40 %.
    expect(s['sd'], 40);
    expect(s['ch'], 6000);
    expect(s['vh'], 600);
    expect(native.ends.single['depth'], 40);
    expect(s['ia'], 1);
  });

  testWidgets('a horizontal list or a small box is not the primary container', (tester) async {
    final native = await screen(
      tester,
      Column(children: [
        SizedBox(height: 100, child: ListView(scrollDirection: Axis.horizontal, children: [for (var i = 0; i < 40; i++) SizedBox(width: 90, child: Text('h$i'))])),
        SizedBox(height: 100, child: ListView(children: [for (var i = 0; i < 40; i++) SizedBox(height: 90, child: Text('v$i'))])),
      ]),
    );
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(native.states.last['sd'], 100);
  });

  testWidgets('a lazy list of a known length uses item positions', (tester) async {
    final native = await screen(
      tester,
      ListView.builder(itemCount: 100, itemBuilder: (_, i) => SizedBox(height: i < 10 ? 60 : 200, child: Text('$i'))),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.fling(scrollable(), const Offset(0, -500), 500);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    final visible = tester.widgetList<Text>(find.byType(Text)).map((t) => int.parse(t.data!)).toList();
    expect(native.states.last['sd'], greaterThanOrEqualTo(10));
    expect(native.states.last['sd'], lessThanOrEqualTo(((visible.last + 1) / 100 * 20).ceil() * 5));
  });

  testWidgets('a list that arrives after the first measure is found at the first touch', (tester) async {
    final loaded = ValueNotifier(false);
    final native = await screen(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: loaded,
        builder: (_, v, __) => v ? ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 100, child: Text('$i'))]) : const SizedBox(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    loaded.value = true;
    await tester.pump();
    await tester.drag(scrollable(), const Offset(0, -600));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(native.states.last['ch'], 6000);
    expect(native.states.last['sd'], 20);
  });

  testWidgets('a heavy page on stage late: its container replaces the first answer, without a touch', (tester) async {
    final shown = ValueNotifier(false);
    final native = await startSdk(tester);
    ScruterEngine.measureRetries = 3;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ScruterObserver()],
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (_, v, __) => v ? SingleChildScrollView(child: Container(height: 6000, color: Colors.red)) : const SizedBox(),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    shown.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(native.states.last['ch'], 6000);
    expect(native.states.last['sd'], 10);
  });

  testWidgets('time per block: the bands of what is visible, engaged time only', (tester) async {
    final native = await screen(tester, SingleChildScrollView(child: Container(height: 6000, color: Colors.red)));
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(seconds: 10));
    await tester.drag(scrollable(), const Offset(0, -3000));
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(seconds: 4));
    await leave(tester);
    final at = (native.states.last['at'] as List).cast<int>();
    expect(at[0], greaterThan(10000));
    expect(at[27], greaterThan(3500));
    expect(at[0], greaterThan(at[27]));
  });

  testWidgets('no scroll listener outlives its screen view', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final native = await screen(tester, ListView(controller: controller, children: [for (var i = 0; i < 60; i++) SizedBox(height: 100, child: Text('$i'))]));
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    await tester.pump(const Duration(milliseconds: 200));
    controller.jumpTo(1000);
    await tester.pump(const Duration(seconds: 1));
    await leave(tester, 'Third');
    expect(native.states.first['sd'], 10);
  });
}
