import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/stack.dart';

import 'support.dart';

class Boom extends StatelessWidget {
  const Boom({super.key});

  @override
  Widget build(BuildContext context) => throw StateError('rendu impossible');
}

void main() {
  test('a symbolic stack: function, file, line, column, in the app or not', () {
    final s = DartStack.parse(StackTrace.fromString('''
#0      Cart.add (package:atelier/cart.dart:12:3)
#1      _HomeState.build.<anonymous closure> (package:atelier/home.dart:40:18)
#2      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1170:21)
<asynchronous suspension>
#3      List.forEach (dart:core-patch/growable_array.dart:416:8)
#4      main (package:scruter_flutter/src/x.dart)
'''));
    expect(s.frames, hasLength(5));
    expect(s.frames[0], {'fn': 'Cart.add', 'fl': 'package:atelier/cart.dart', 'l': 12, 'co': 3, 'ia': true});
    expect(s.frames[1]['fn'], '_HomeState.build.<anonymous closure>');
    expect(s.frames[2]['ia'], isFalse);
    expect(s.frames[3]['ia'], isFalse);
    expect(s.frames[4]['ia'], isFalse);
    expect(s.buildId, isNull);
    expect(s.images, isEmpty);
  });

  test('a non-symbolic stack: virtual addresses against the snapshot of its build id', () {
    final s = DartStack.parse(StackTrace.fromString('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 4021, tid: 4040, name 1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '7d7673e24f49333c350d63b3c4961365'
isolate_dso_base: 723d447000, vm_dso_base: 723d447000
isolate_instructions: 723d4ee000, vm_instructions: 723d4e7000
    #00 abs 000000723d6346d7 virt 00000000001ed6d7 _kDartIsolateSnapshotInstructions+0x1466d7
    #01 abs 000000723d634711 virt 00000000001ed711 _kDartIsolateSnapshotInstructions+0x146711
'''));
    expect(s.buildId, '7d7673e24f49333c350d63b3c4961365');
    expect(s.frames, [
      {'a': '0x1ed6d7', 'i': 0},
      {'a': '0x1ed711', 'i': 0},
    ]);
    expect(s.images.single['u'], '7d7673e24f49333c350d63b3c4961365');
    expect(s.images.single['la'], '0x0');
    expect(s.images.single['ar'], 'arm64');
  });

  test('without a virtual address: relative to the snapshot', () {
    final s = DartStack.parse(StackTrace.fromString('''
build_id: 'abcd'
isolate_dso_base: 1000, vm_dso_base: 1000
    #00 abs 0000000000001234 _kDartIsolateSnapshotInstructions+0x234
'''));
    expect(s.frames.single['a'], '0x234');
  });

  test('an empty stack still gives one frame, a long one 64', () {
    expect(DartStack.parse(StackTrace.empty).frames.single, {'fn': '?'});
    final long = List.generate(100, (i) => '#$i      f$i (package:a/b.dart:$i:1)').join('\n');
    expect(DartStack.parse(StackTrace.fromString(long)).frames, hasLength(64));
  });

  testWidgets('a widget error: nonfatal, chained to the previous handler', (tester) async {
    final previous = FlutterError.onError;
    final seen = <FlutterErrorDetails>[];
    FlutterError.onError = seen.add;
    final native = await startSdk(tester);
    addTearDown(() => FlutterError.onError = previous);
    await tester.pumpWidget(const MaterialApp(home: Boom()));
    expect(seen, hasLength(1));
    final r = native.args('reportError').single;
    expect(r['fatal'], isFalse);
    expect(r['type'], 'StateError');
    expect(r['reason'], contains('rendu impossible'));
    expect(r['frames'], isNotEmpty);
    conformance('batch', 'crash-widget', batchOf(crashes: [_item(r)]));
  });

  testWidgets('an error at every frame is reported once a second', (tester) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    final native = await startSdk(tester);
    addTearDown(() => FlutterError.onError = previous);
    for (var i = 0; i < 5; i++) {
      FlutterError.reportError(FlutterErrorDetails(exception: StateError('x'), stack: StackTrace.fromString('#0 f (package:a/b.dart:1:1)')));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(native.args('reportError'), hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    FlutterError.reportError(FlutterErrorDetails(exception: StateError('x'), stack: StackTrace.fromString('#0 f (package:a/b.dart:1:1)')));
    await tester.pump();
    expect(native.args('reportError'), hasLength(2));
  });

  testWidgets('silent errors stay silent', (tester) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    final native = await startSdk(tester);
    addTearDown(() => FlutterError.onError = previous);
    FlutterError.reportError(FlutterErrorDetails(exception: StateError('x'), silent: true));
    await tester.pump();
    expect(native.args('reportError'), isEmpty);
  });

  testWidgets('PlatformDispatcher.onError: chained, the answer is the previous handler\'s', (tester) async {
    final dispatcher = PlatformDispatcher.instance;
    final previous = dispatcher.onError;
    var calls = 0;
    dispatcher.onError = (e, s) {
      calls++;
      return true;
    };
    final native = await startSdk(tester);
    addTearDown(() => dispatcher.onError = previous);
    expect(dispatcher.onError!(ArgumentError('x'), StackTrace.current), isTrue);
    await tester.pump();
    expect(calls, 1);
    expect(native.args('reportError').single['type'], 'ArgumentError');
  });

  testWidgets('a handler set after start without chaining does not cut the SDK off', (tester) async {
    final previous = FlutterError.onError;
    final native = await startSdk(tester);
    addTearDown(() => FlutterError.onError = previous);
    var theirs = 0;
    FlutterError.onError = (_) => theirs++;
    await tester.pumpWidget(const SizedBox());
    FlutterError.reportError(FlutterErrorDetails(exception: StateError('x')));
    await tester.pump();
    expect(theirs, 1);
    expect(native.args('reportError'), hasLength(1));
  });

  testWidgets('Scruter.reportError: a caught error, fatal when the app says so', (tester) async {
    final native = await startSdk(tester);
    try {
      throw const FormatException('nope');
    } catch (e, s) {
      Scruter.reportError(e, s, fatal: true);
    }
    await tester.pump();
    final r = native.args('reportError').single;
    expect(r['fatal'], isTrue);
    expect(r['type'], 'FormatException');
  });
}

Map<String, Object?> _item(Map<dynamic, dynamic> r) => {
      's': session,
      'id': 'a1b2c3d4e5f60718',
      't': 1762345214000,
      'k': r['fatal'] == true ? 'crash' : 'nonfatal',
      'src': 'dart',
      'ex': {'type': r['type'], 'reason': r['reason']},
      'th': [
        {
          'c': 1,
          'm': 1,
          'f': [
            for (final f in r['frames'] as List)
              {
                for (final e in (f as Map).entries)
                  if (e.key == 'ia') 'ia': e.value == true ? 1 : 0 else e.key as String: e.value,
              },
          ],
        },
      ],
    };
