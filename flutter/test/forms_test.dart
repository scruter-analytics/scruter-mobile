import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

import 'support.dart';

void main() {
  late GlobalKey<NavigatorState> nav;

  Future<FakeNative> screen(WidgetTester tester, Widget body) async {
    nav = GlobalKey<NavigatorState>();
    final native = await startSdk(tester);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [ScruterObserver()],
      home: Scaffold(body: body),
      onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => const Scaffold()),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return native;
  }

  Map<String, dynamic> formOf(FakeNative n, [String? name]) {
    final forms = (n.states.last['f'] as List).cast<Map<String, dynamic>>();
    return name == null ? forms.single : forms.firstWhere((f) => f['s'] == name);
  }

  List<List<dynamic>> fieldsOf(Map<String, dynamic> form) => (form['fd'] as List).cast<List<dynamic>>();

  testWidgets('focus, hesitation, change, last field: never a value', (tester) async {
    final native = await screen(
      tester,
      Column(children: const [
        TextField(autofillHints: [AutofillHints.postalCode]),
        TextField(autofillHints: [AutofillHints.email], keyboardType: TextInputType.emailAddress),
        TextField(key: ValueKey('city')),
        TextField(maxLines: 3),
      ]),
    );
    await tester.tap(find.byType(TextField).first);
    await tester.pump(const Duration(seconds: 4));
    await tester.enterText(find.byType(TextField).first, '75011');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(TextField).at(2));
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final form = formOf(native);
    expect(form['s'], '/', reason: "the screen's form");
    expect(form['b'], 1);
    expect(form['lf'], 'city');
    final fields = fieldsOf(form);
    expect(fields.map((f) => f[0]), ['postalCode', 'emailAddress', 'city', 'textarea:3']);
    expect(fields.map((f) => f[1]), ['text', 'email', 'text', 'textarea']);
    final postal = fields.first;
    expect(postal[4], greaterThanOrEqualTo(1));
    expect(postal[5], greaterThanOrEqualTo(4000));
    expect(postal[8], 1);
    expect(fields[2][8], 0);
    final all = native.calls.map((c) => c.arguments.toString()).join();
    expect(all, isNot(contains('75011')));
  });

  testWidgets('passwords, codes and payment fields are ignored entirely', (tester) async {
    final native = await screen(
      tester,
      Column(children: const [
        TextField(obscureText: true),
        TextField(autofillHints: [AutofillHints.oneTimeCode]),
        TextField(autofillHints: [AutofillHints.creditCardNumber]),
        TextField(key: ValueKey('cardNumber')),
        TextField(keyboardType: TextInputType.visiblePassword),
        TextField(key: ValueKey('city')),
      ]),
    );
    await tester.tap(find.byType(TextField).first);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(TextField).last);
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    expect(fieldsOf(formOf(native)).map((f) => f[0]), ['city']);
  });

  testWidgets('grouping: ScruterForm, a Form with an identifier, else the screen', (tester) async {
    final native = await screen(
      tester,
      Column(children: const [
        ScruterForm('Delivery', child: TextField(key: ValueKey('street'))),
        Form(key: ValueKey('newsletter'), child: TextField(key: ValueKey('mail'))),
        Form(child: TextField(key: ValueKey('alone'))),
      ]),
    );
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final forms = (native.states.last['f'] as List).cast<Map<String, dynamic>>();
    expect(forms.map((f) => f['s']).toSet(), {'Delivery', 'newsletter', '/'});
    expect(forms.map((f) => f['i']), [0, 1, 2]);
  });

  testWidgets('errors from InputDecoration, through a validator, and a refused attempt', (tester) async {
    final key = GlobalKey<FormState>();
    final native = await screen(
      tester,
      Form(
        key: key,
        child: Column(children: [
          TextFormField(key: const ValueKey('postalCode'), validator: (v) => (v ?? '').length == 5 ? null : 'Postal code of 5 digits'),
          ElevatedButton(onPressed: () => key.currentState!.validate(), child: const Text('Submit')),
        ]),
      ),
    );
    await tester.tap(find.byType(TextFormField));
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextFormField), '123');
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final form = formOf(native);
    expect(form['rf'], 1);
    expect(form['ok'], 0);
    final f = fieldsOf(form).single;
    expect(f[6], 1);
    expect(f[7], 8);
    expect(native.calls.map((c) => c.arguments.toString()).join(), isNot(contains('Postal code')));
  });

  testWidgets('an error of a choice FormField', (tester) async {
    final key = GlobalKey<FormState>();
    final native = await screen(
      tester,
      Form(
        key: key,
        child: Column(children: [
          DropdownButtonFormField<String>(
            key: const ValueKey('country'),
            items: const [DropdownMenuItem(value: 'fr', child: Text('France'))],
            onChanged: (_) {},
            validator: (v) => v == null ? 'Required' : null,
          ),
          ElevatedButton(onPressed: () => key.currentState!.validate(), child: const Text('Submit')),
          const TextField(key: ValueKey('name')),
        ]),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Submit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await leave(tester);
    expect(formOf(native)['rf'], 1);
  });

  testWidgets('sent automatically when leaving forward after a change, without an error', (tester) async {
    final native = await screen(tester, const TextField(key: ValueKey('city')));
    await tester.enterText(find.byType(TextField), 'Lyon');
    await tester.pump(const Duration(seconds: 2));
    nav.currentState!.pushNamed('/next');
    await tester.pumpAndSettle();
    final form = (native.states.first['f'] as List).cast<Map<String, dynamic>>().single;
    expect(form['ok'], 1);
    expect(form['ms'], greaterThanOrEqualTo(2000));
  });

  testWidgets('not sent when leaving back, nor with an error showing', (tester) async {
    final native = await screen(
      tester,
      const TextField(key: ValueKey('city'), decoration: InputDecoration(errorText: 'No')),
    );
    await tester.enterText(find.byType(TextField), 'Lyon');
    await tester.pump(const Duration(seconds: 1));
    nav.currentState!.pushNamed('/next');
    await tester.pumpAndSettle();
    final form = (native.states.first['f'] as List).cast<Map<String, dynamic>>().single;
    expect(form['ok'], 0);
    expect(fieldsOf(form).single[6], 1);
  });

  testWidgets('Scruter.formSent and Scruter.fieldError', (tester) async {
    final native = await screen(tester, const ScruterForm('Contact', child: TextField(key: ValueKey('phone'))));
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(seconds: 1));
    Scruter.fieldError('phone', ScruterFieldError.format);
    Scruter.formSent('Contact');
    await leave(tester);
    final form = formOf(native);
    expect(form['ok'], 1);
    expect(fieldsOf(form).single[7], 2);
  });

  testWidgets('choices: position, type, change on tap', (tester) async {
    final value = ValueNotifier(false);
    final native = await screen(
      tester,
      Column(children: [
        ValueListenableBuilder<bool>(valueListenable: value, builder: (_, v, __) => Switch(value: v, onChanged: (x) => value.value = x)),
        Checkbox(value: false, onChanged: (_) {}),
      ]),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final fields = fieldsOf(formOf(native));
    expect(fields.map((f) => f[0]), ['switch:0', 'checkbox:1']);
    expect(fields.first[8], 1);
    expect(fields.first[4], 1);
    expect(fields.last[8], 0);
  });

  testWidgets('caps: 10 forms of 40 fields', (tester) async {
    final native = await screen(
      tester,
      SingleChildScrollView(
        child: Column(children: [
          for (var f = 0; f < 12; f++)
            ScruterForm('Form$f', child: Column(children: [for (var i = 0; i < 3; i++) SizedBox(height: 30, child: TextField(key: ValueKey('f${f}x$i')))])),
          ScruterForm('Big', child: Column(children: [for (var i = 0; i < 50; i++) const SizedBox(height: 30, child: TextField())])),
        ]),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final forms = native.states.last['f'] as List;
    expect(forms, hasLength(10));
  });

  testWidgets('no listener outlives the screen view', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final native = await screen(tester, TextField(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    await leave(tester);
    final count = native.states.length;
    controller.text = 'after';
    await tester.pump();
    expect(native.states, hasLength(count));
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(controller.hasListeners, isTrue, reason: "the TextField's own");
  });

  testWidgets('a key press keeps the session engaged', (tester) async {
    final native = await screen(tester, const TextField());
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump(const Duration(seconds: 70));
    tester.testTextInput.enterText('x');
    await tester.pump(const Duration(seconds: 5));
    await leave(tester);
    expect(native.states.last['et'], greaterThan(60000));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  });
}
