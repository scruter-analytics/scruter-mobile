import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

import 'support.dart';

/// What the Dart layer produces, written for `scripts/conformance.sh`: the batch schema of `sdk/protocol` checks the
/// analysed screen views, the `screen_end` events and the Dart crash reports, the team-screen schema the element tree.
void main() {
  testWidgets('a screen with everything', (tester) async {
    final native = await startSdk(tester);
    final key = GlobalKey<FormState>();
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ScruterObserver()],
      home: Scaffold(
        body: Form(
          key: key,
          child: ListView(children: [
            TextFormField(key: const ValueKey('postalCode'), validator: (v) => 'No'),
            CheckboxListTile(value: false, onChanged: (_) {}),
            ElevatedButton(onPressed: () => key.currentState!.validate(), child: const Text('Submit')),
            for (var i = 0; i < 40; i++) ListTile(title: Text('Line $i'), onTap: () {}),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(TextFormField));
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextFormField), 'x');
    await tester.tap(find.text('Submit'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Line 2'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump(const Duration(seconds: 2));
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(native.states, isNotEmpty);
    final events = [
      for (final e in native.ends)
        <String, Object?>{'s': e['session'], 'k': 'screen_end', 'n': e['name'], 't': 1762345142000, 'ms': e['ms'], 'sc': e['depth']},
    ];
    conformance('batch', 'dart-layer', batchOf(states: native.states, events: events));
  });
}
