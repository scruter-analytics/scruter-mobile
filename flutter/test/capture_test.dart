import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/tree.dart';

import 'support.dart';

/// Lets a capture run: real image work (`runAsync`), and the fake clock for its timers and frames.
Future<void> runCapture(WidgetTester tester, FakeNative native) async {
  await tester.pump(const Duration(milliseconds: 1600));
  for (var i = 0; i < 400; i++) {
    if (native.calls.any((c) => c.method == 'imageFinish' || c.method == 'imageCancel')) break;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 70));
  }
}

Map<String, dynamic> treeOf(FakeNative native) =>
    jsonDecode(native.args('imageFinish').single['tree'] as String) as Map<String, dynamic>;

List<Map<String, dynamic>> nodesOf(FakeNative native) => (treeOf(native)['nodes'] as List).cast<Map<String, dynamic>>();

int pixel(Map<String, Object?> strip, int x, int y) {
  final w = strip['width']! as int;
  return ByteData.sublistView(strip['rgba']! as Uint8List).getUint32((y * w + x) * 4, Endian.little);
}

void main() {
  Future<FakeNative> screen(WidgetTester tester, Widget body, {bool capture = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final native = await startSdk(tester, capture: capture);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ScruterObserver()],
      theme: ThemeData(useMaterial3: false),
      home: Scaffold(backgroundColor: Colors.white, body: body),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return native;
  }

  testWidgets('a user\'s phone takes no image', (tester) async {
    final native = await screen(tester, const Text('x'), capture: false);
    await tester.pump(const Duration(seconds: 5));
    expect(native.calls.where((c) => c.method.startsWith('image')), isEmpty);
  });

  testWidgets('one image: masks in the pixels, a tree with labels, none on what is masked', (tester) async {
    final native = await screen(
      tester,
      Column(children: [
        ElevatedButton(key: const ValueKey('buy'), onPressed: () {}, child: const Text('Buy')),
        SizedBox(width: 300, child: TextField(controller: TextEditingController(text: 'jane@example.com'))),
        const ScruterMask(child: Text('12 Lilac Street')),
        const SizedBox(height: 40),
      ]),
    );
    await runCapture(tester, native);
    expect(native.calls.where((c) => c.method == 'imageCancel'), isEmpty);
    final begin = native.args('imageBegin').single;
    expect(begin['width'], 800);
    final finish = native.args('imageFinish').single;
    expect(finish['screen'], '/');
    expect(finish['rows'], 600);
    expect(finish['scale'], 1.0);
    final nodes = nodesOf(native);
    conformance('team-screen#tree', 'tree', treeOf(native));
    final buy = nodes.firstWhere((n) => n['s'] == '#buy');
    expect(buy['k'], 'button');
    expect(buy['l'], 'Buy');
    final input = nodes.firstWhere((n) => n['k'] == 'input');
    expect(input['m'], 1);
    expect(input.containsKey('l'), isFalse);
    final mask = nodes.firstWhere((n) => n['m'] == 1 && n['k'] != 'input');
    expect(mask.containsKey('l'), isFalse);
    expect(native.args('imageFinish').single['tree'], isNot(contains('jane')));
    expect(native.args('imageFinish').single['tree'], isNot(contains('Lilac')));
    final strip = native.strips.single;
    expect(strip['y'], 0);
    expect(strip['rows'], 600);
    // Opaque rectangles, in the bytes that leave Dart.
    final x = (mask['x'] as int) + (mask['w'] as int) ~/ 2;
    final y = (mask['y'] as int) + (mask['h'] as int) ~/ 2;
    expect(pixel(strip, x, y), 0xFFBDBDBD);
    final ix = (input['x'] as int) + (input['w'] as int) ~/ 2;
    final iy = (input['y'] as int) + (input['h'] as int) ~/ 2;
    expect(pixel(strip, ix, iy), 0xFFBDBDBD);
  });

  testWidgets('a long screen is stitched, then scrolled back', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final native = await screen(
      tester,
      ListView(
        controller: controller,
        children: [
          for (var i = 0; i < 30; i++)
            Container(
              key: ValueKey('row$i'),
              height: 100,
              color: i.isEven ? const Color(0xFF112233) : const Color(0xFF445566),
            ),
        ],
      ),
    );
    await runCapture(tester, native);
    expect(native.args('imageFinish').single['rows'], 3000);
    expect(controller.offset, 0);
    var y = 0;
    for (final s in native.strips) {
      expect(s['y'], y);
      y += s['rows']! as int;
    }
    expect(y, 3000);
    final rows = nodesOf(native).where((n) => (n['s'] as String).contains('row') || n['k'] == 'cell').toList();
    expect(rows, hasLength(30));
    final row20 = rows.firstWhere((n) => n['i'] == 20);
    expect(row20['y'], 2000);
    expect(nodesOf(native).map((n) => '${n['s']}#${n['i']}').toSet(), hasLength(nodesOf(native).length));
  });

  testWidgets('what surrounds the scroll container appears once', (tester) async {
    final native = await screen(
      tester,
      Column(children: [
        const SizedBox(height: 50, child: Text('top')),
        Expanded(child: ListView(children: [for (var i = 0; i < 20; i++) SizedBox(height: 100, child: Text('l$i'))])),
        const SizedBox(height: 50, child: Text('bottom')),
      ]),
    );
    await runCapture(tester, native);
    expect(native.args('imageFinish').single['rows'], 2100);
    final nodes = nodesOf(native);
    expect(nodes.firstWhere((n) => n['l'] == 'top')['y'], lessThan(50));
    expect(nodes.firstWhere((n) => n['l'] == 'bottom')['y'], greaterThanOrEqualTo(2050));
  });

  testWidgets('web views are `web`, other platform views `media`: masked, without label, in the pixels', (tester) async {
    Widget view(String type) => SizedBox(
          width: 300,
          height: 100,
          child: UiKitView(viewType: type, key: ValueKey(type)),
        );
    final platforms = _FakePlatformViews()..install();
    addTearDown(platforms.uninstall);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final native = await screen(
      tester,
      Column(children: [
        view('plugins.flutter.io/webview'),
        view('com.pichillilorenzo/flutter_inappwebview'),
        view('plugins.flutter.io/google_maps'),
      ]),
    );
    await runCapture(tester, native);
    debugDefaultTargetPlatformOverride = null;
    final nodes = nodesOf(native);
    conformance('team-screen#tree', 'web-views', treeOf(native));
    final platform = nodes.where((n) => n['k'] == 'web' || n['k'] == 'media').toList();
    expect(platform.map((n) => n['k']), ['web', 'web', 'media']);
    final strip = native.strips.single;
    for (final n in platform) {
      expect(n['m'], 1);
      expect(n.containsKey('l'), isFalse);
      expect(pixel(strip, (n['x'] as int) + 20, (n['y'] as int) + 20), 0xFFBDBDBD);
    }
  });

  testWidgets('a web view keeps its kind under a keyed wrapper and as a list item, and is never a tap target', (tester) async {
    final platforms = _FakePlatformViews()..install();
    addTearDown(platforms.uninstall);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const web = UiKitView(viewType: 'plugins.flutter.io/webview');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: const [
          SizedBox(height: 100, child: web),
          ScruterId('article', child: SizedBox(height: 100, child: web)),
        ]),
      ),
    ));
    await tester.pump();
    final t = ScreenTree.build(tester.element(find.byType(Scaffold)), labels: true);
    final items = t.nodes.where((n) => n.item != null).toList();
    debugDefaultTargetPlatformOverride = null;
    expect(items.map((n) => n.kind), ['web', 'web']);
    expect(items.every((n) => n.masked && n.label == null), isTrue);
  });

  testWidgets('a very tall screen stays under the memory ceiling, below 2×', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1170, 2532);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final native = await startSdk(tester, capture: true);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ScruterObserver()],
      home: Scaffold(body: ListView(children: [for (var i = 0; i < 100; i++) SizedBox(height: 100, child: Text('$i'))])),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await runCapture(tester, native);
    final begin = native.args('imageBegin').single;
    final pixels = (begin['width'] as int) * (begin['rows'] as int);
    expect(pixels, lessThanOrEqualTo(10000000));
    expect(native.args('imageFinish').single['scale'], lessThan(2));
  });

  testWidgets('never while a spinner turns; a screen left stops the capture', (tester) async {
    final native = await screen(tester, const Center(child: CircularProgressIndicator()));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(native.calls.where((c) => c.method.startsWith('image')), isEmpty);
    native.capture = false;
    final second = await _left(tester, native);
    expect(second, isEmpty);
  });

  testWidgets('a RepaintBoundary of the page exists on a route', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(find.byType(RepaintBoundary), findsWidgets);
    expect(tester.renderObject(find.byType(RepaintBoundary).first), isA<RenderRepaintBoundary>());
  });
}

/// Answers the engine's platform view calls, so that a `UiKitView` builds in a test.
class _FakePlatformViews {
  var _id = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async => call.method == 'create' ? _id++ : null);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  }
}

Future<List<MethodCallLike>> _left(WidgetTester tester, FakeNative native) async {
  await leave(tester);
  await tester.pump(const Duration(seconds: 3));
  return native.calls.where((c) => c.method.startsWith('image')).map((c) => MethodCallLike(c.method)).toList();
}

class MethodCallLike {
  MethodCallLike(this.method);

  final String method;
}
