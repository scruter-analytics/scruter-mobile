import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

import 'support.dart';

class Counter extends StatefulWidget {
  const Counter({super.key});

  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: 200, height: 40, child: Text('$n')),
      );
}

void main() {
  Future<FakeNative> screen(WidgetTester tester, Widget body, {bool analysed = true}) async {
    final native = await startSdk(tester, analysed: analysed);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ScruterObserver()],
      home: Scaffold(body: body),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return native;
  }

  testWidgets('a tap on a button: selector, index, kind, position inside it', (tester) async {
    var pressed = 0;
    final native = await screen(
      tester,
      Center(
        child: SizedBox(
          width: 200,
          height: 100,
          child: ElevatedButton(key: const ValueKey('buy'), onPressed: () => pressed++, child: const Text('Buy')),
        ),
      ),
    );
    final box = tester.getRect(find.byKey(const ValueKey('buy')));
    await tester.tapAt(box.topLeft + const Offset(50, 25));
    await tester.pump();
    expect(pressed, 1, reason: 'the SDK only watches');
    await leave(tester);
    expect(native.taps.single, ['#buy', 0, 'button', 25, 25, greaterThan(0), 0]);
    expect(native.states.first['cn'], 1);
  });

  testWidgets('a text inside a button is the button; a plain text is itself', (tester) async {
    final native = await screen(
      tester,
      Column(children: [
        TextButton(onPressed: () {}, child: const Text('View')),
        const Text('Paragraphe'),
      ]),
    );
    await tester.tap(find.text('View'));
    await tester.pump();
    await tester.tap(find.text('Paragraphe'));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.map((t) => t[0]), ['TextButton', 'Text']);
    expect(native.taps[1][2], 'text');
  });

  testWidgets('a dead tap: nothing happens within a second', (tester) async {
    final native = await screen(tester, const Center(child: Text('Does nothing')));
    await tester.tap(find.text('Does nothing'));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[6], 1);
    expect(native.states.first['cd'], 1);
  });

  testWidgets('a disabled button is not interactive: its taps can be dead', (tester) async {
    final native = await screen(tester, const Center(child: ElevatedButton(onPressed: null, child: Text('Payer'))));
    await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[6], 1);
  });

  testWidgets('a tap followed by a new element tree is not dead', (tester) async {
    final shown = ValueNotifier(false);
    final native = await screen(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (_, v, __) => Column(children: [const Text('Fold'), if (v) const Text('Unfolded')]),
      ),
    );
    await tester.tap(find.text('Fold'));
    await tester.pump(const Duration(milliseconds: 300));
    shown.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[6], 0);
  });

  testWidgets('a tap followed by a focus change or a route is not dead', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final native = await screen(tester, Column(children: [const Text('Here'), Focus(focusNode: focus, child: const SizedBox())]));
    await tester.tap(find.text('Here'));
    await tester.pump(const Duration(milliseconds: 100));
    focus.requestFocus();
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[6], 0);
  });

  testWidgets('a screen change settles a waiting tap as not dead', (tester) async {
    final native = await screen(tester, const Text('Here'));
    await tester.tap(find.text('Here'));
    await tester.pump(const Duration(milliseconds: 100));
    await leave(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(native.taps.single[6], 0);
  });

  testWidgets('rage: the third tap within a second inside 24 points, one flag per burst', (tester) async {
    final native = await screen(tester, Center(child: ElevatedButton(onPressed: () {}, child: const Text('Quick'))));
    final at = tester.getCenter(find.text('Quick'));
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(at + Offset(i.toDouble(), 0));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await leave(tester);
    expect(native.taps.map((t) => t[6]), [0, 0, 2, 0, 0]);
    expect(native.states.last['cr'], 1);
  });

  testWidgets('a scroll, a long press and a two-finger touch are not taps', (tester) async {
    final native = await screen(tester, ListView(children: [for (var i = 0; i < 40; i++) SizedBox(height: 80, child: Text('$i'))]));
    await tester.drag(find.text('3'), const Offset(0, -200));
    await tester.pump();
    final g = await tester.startGesture(tester.getCenter(find.text('4')));
    await tester.pump(const Duration(seconds: 1));
    await g.up();
    await tester.pump();
    final a = await tester.startGesture(const Offset(100, 100), pointer: 7);
    final b = await tester.startGesture(const Offset(200, 100), pointer: 8);
    await a.up();
    await b.up();
    await tester.pump();
    await leave(tester);
    expect(native.taps, isEmpty);
  });

  testWidgets('nothing inside a masked or ignored element is a target', (tester) async {
    final native = await screen(
      tester,
      Column(children: [
        ScruterMask(child: TextButton(onPressed: () {}, child: const Text('Masked'))),
        ScruterIgnore(child: TextButton(onPressed: () {}, child: const Text('Ignored'))),
      ]),
    );
    await tester.tap(find.text('Masked'));
    await tester.tap(find.text('Ignored'));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps, isEmpty);
  });

  testWidgets('a text field is a target of kind input, never a label or a value', (tester) async {
    final native = await screen(tester, TextField(controller: TextEditingController(text: 'jane@example.com')));
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[0], 'TextField');
    expect(native.taps.single[2], 'input');
    expect(native.calls.map((c) => c.arguments.toString()).join(), isNot(contains('jane')));
  });

  testWidgets('a link in a paragraph is a link', (tester) async {
    final recognizer = TapGestureRecognizer()..onTap = () {};
    addTearDown(recognizer.dispose);
    final native = await screen(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: RichText(text: TextSpan(text: 'lien', style: const TextStyle(color: Colors.black), recognizer: recognizer)),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(RichText)));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[2], 'link');
    expect(native.taps.single[6], 0);
  });

  testWidgets('a tap outside the page: the app root gives the element (a shell, a dialog)', (tester) async {
    final native = await startSdk(tester);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NavigationBar(destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.shop), label: 'Shop'),
        ]),
        body: Navigator(
          key: nav,
          observers: [ScruterObserver()],
          onGenerateRoute: (s) => MaterialPageRoute<void>(settings: const RouteSettings(name: 'Page'), builder: (_) => const Text('page')),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Shop'));
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(native.taps.single[2], 'tab');
    expect(native.taps.single[1], 1);
  });

  testWidgets('outside the sample nothing is identified, engagement still counts', (tester) async {
    final native = await screen(tester, ElevatedButton(onPressed: () {}, child: const Text('x')), analysed: false);
    await tester.tap(find.text('x'));
    await tester.pump(const Duration(seconds: 3));
    await leave(tester);
    expect(native.states, isEmpty);
    expect(native.ends.single['name'], '/');
    expect(native.ends.single['depth'], 100);
  });

  testWidgets('no frame of its own: a screen, a tap and a scroll schedule what they schedule without the SDK', (tester) async {
    Future<List<bool>> journey(List<NavigatorObserver> observers) async {
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        navigatorObservers: observers,
        home: Scaffold(body: ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 100, child: Text('$i'))])),
      ));
      final frames = <bool>[];
      await tester.pump(const Duration(seconds: 1));
      frames.add(tester.binding.hasScheduledFrame);
      await tester.tap(find.text('2'));
      frames.add(tester.binding.hasScheduledFrame);
      await tester.pump(const Duration(seconds: 2));
      frames.add(tester.binding.hasScheduledFrame);
      await tester.drag(find.text('3'), const Offset(0, -300));
      frames.add(tester.binding.hasScheduledFrame);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      frames.add(tester.binding.hasScheduledFrame);
      return frames;
    }

    final without = await journey(const []);
    final native = await startSdk(tester);
    final measured = await journey([ScruterObserver()]);
    await leave(tester);
    expect(measured, without);
    expect(measured.last, isFalse);
    expect(native.taps, hasLength(1));
  });

  testWidgets('at most 300 taps per screen view, a state every 100', (tester) async {
    final native = await screen(tester, Center(child: ElevatedButton(onPressed: () {}, child: const Text('x'))));
    final at = tester.getCenter(find.text('x'));
    for (var i = 0; i < 305; i++) {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 500));
    }
    await leave(tester);
    expect(native.taps, hasLength(300));
    expect(native.states.every((s) => (s['c'] as List? ?? const []).length <= 100), isTrue);
    expect(native.states.last['cn'], 300);
  });
}
