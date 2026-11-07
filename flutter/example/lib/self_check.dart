import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/tree.dart';

/// Drives the app by itself, with real pointer events through Flutter's gesture binding, so that the same journey runs
/// on an emulator, on a simulator and in a release build (where `flutter_test` does not): scripts/device-check.mjs
/// starts it and checks what reaches its server. Prints the timings the release build measures.
class SelfCheck {
  SelfCheck(this.router, this.navigator, this.endpoint, this.startUs);

  final GoRouter router;
  final GlobalKey<NavigatorState> navigator;
  final String endpoint;

  /// `Scruter.start`, on the main isolate.
  final int startUs;
  int _pointer = 1000;
  static const _captureMs = 6000;
  static const _presentTries = 150;

  /// The journey, then what it found: a step that fails says which one at once, instead of leaving the script to wait.
  Future<void> run() async {
    String? failed;
    try {
      await _journey();
    } catch (e) {
      failed = '$e';
    }
    final client = HttpClient();
    final request = await client.postUrl(Uri.parse('$endpoint/self-check'));
    request.write(jsonEncode({'startUs': startUs, 'tree': _tree, if (failed != null) 'failed': failed}));
    await (await request.close()).drain<void>();
    client.close();
  }

  Future<void> _journey() async {
    // On a team phone, each new screen is scrolled through for its image: the journey goes on after that.
    await _wait(_captureMs + 2000);
    await _tapKey(const ValueKey('products'), dy: 120);
    await _wait(_captureMs);
    await _drag(-900);
    await _wait(800);
    await _tapText('A description with no link, which does not react.', orScroll: true);
    await _wait(1800);
    await _tapKey(const ValueKey('addToCart'), scroll: true);
    await _wait(_captureMs);
    await _focusAndType(const ValueKey('email'), 'jane@example.com');
    await _focusAndType(const ValueKey('postalCode'), '12');
    await _focusAndType(const ValueKey('accountPassword'), 'hunter2');
    await _tapKey(const ValueKey('news'));
    await _wait(300);
    await _tapKey(const ValueKey('pay'));
    await _wait(1500);
    await _focusAndType(const ValueKey('postalCode'), '75011');
    await _tapKey(const ValueKey('pay'));
    await _wait(2500);
    FlutterError.reportError(FlutterErrorDetails(exception: StateError('self-check'), stack: StackTrace.current));
    await _measureTaps();
    router.go('/');
    await _wait(1500);
    Scruter.flush();
    await _wait(1500);
    if (Platform.isIOS) Scruter.handleLink('scruter-atmona02://team?t=scr_qr_${'a' * 32}');
    await _wait(1500);
  }

  /// An element of the next step: a slow emulator (API 24, software rendering) lays a page out later than any fixed
  /// wait assumes, so a step waits for what it needs.
  Future<Element?> _present(bool Function(Widget) test) async {
    for (var i = 0; i < _presentTries; i++) {
      final e = _find(test);
      if (e != null) return e;
      await _wait(200);
    }
    return null;
  }

  Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Element? _find(bool Function(Widget) test) {
    Element? found;
    void walk(Element e) {
      if (found != null) return;
      if (test(e.widget)) {
        found = e;
        return;
      }
      e.debugVisitOnstageChildren(walk);
    }

    WidgetsBinding.instance.rootElement?.debugVisitOnstageChildren(walk);
    return found;
  }

  Offset _center(Element e, {double? dy}) {
    final box = e.renderObject! as RenderBox;
    final at = box.localToGlobal(Offset.zero);
    return dy == null ? box.localToGlobal(box.size.center(Offset.zero)) : at + Offset(box.size.width / 2, dy);
  }

  Future<void> _pointerTap(Offset at) async {
    final id = _pointer++;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: id, position: at));
    await _wait(40);
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: id, position: at));
    await _wait(50);
  }

  Future<void> _drag(double dy) async {
    final size = WidgetsBinding.instance.platformDispatcher.views.first;
    final start = Offset(size.physicalSize.width / size.devicePixelRatio / 2, size.physicalSize.height / size.devicePixelRatio * 0.75);
    final id = _pointer++;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: id, position: start));
    for (var i = 1; i <= 12; i++) {
      await _wait(16);
      final delta = Offset(0, dy / 12);
      GestureBinding.instance.handlePointerEvent(PointerMoveEvent(pointer: id, position: start + delta * i.toDouble(), delta: delta));
    }
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: id, position: start + Offset(0, dy)));
    await _wait(300);
  }

  Future<void> _tapKey(Key key, {double? dy, bool scroll = false}) async {
    var e = await _present((w) => w.key == key || (w is ScruterId && key == ValueKey(w.id)));
    if (scroll && e != null) {
      await Scrollable.ensureVisible(e, duration: const Duration(milliseconds: 200));
      await _wait(400);
      e = _find((w) => w.key == key || (w is ScruterId && key == ValueKey(w.id)));
    }
    if (e == null) throw StateError('self-check: no $key');
    await _pointerTap(_center(e, dy: dy));
  }

  Future<void> _tapText(String text, {bool orScroll = false}) async {
    final e = await _present((w) => w is Text && w.data == text);
    if (e == null) throw StateError('self-check: no text $text');
    if (orScroll) {
      await Scrollable.ensureVisible(e);
      await _wait(300);
    }
    await _pointerTap(_center(e));
  }

  Future<void> _focusAndType(Key key, String text) async {
    await _tapKey(key);
    await _wait(500);
    final e = _find((w) => w.key == key);
    EditableTextState? editable;
    void walk(Element x) {
      if (x is StatefulElement && x.state is EditableTextState) editable ??= x.state as EditableTextState;
      x.visitChildren(walk);
    }

    if (e != null) walk(e);
    // What the platform's text input does at each key.
    editable?.updateEditingValue(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)));
    await _wait(400);
  }

  /// §3.18: the identity of a tap on a screen of 2 000 elements, in this build's mode.
  Future<void> _measureTaps() async {
    router.push('/heavy');
    await _wait(1500);
    await _tapKey(const ValueKey('middle'), scroll: true);
    await _wait(1200);
    final target = _find((w) => w.key == const ValueKey('middle'))!;
    final render = target.renderObject!;
    final root = _find((w) => w is Scaffold)!;
    final times = <int>[];
    var nodes = 0;
    for (var i = 0; i < 21; i++) {
      final watch = Stopwatch()..start();
      final t = ScreenTree.build(root, hit: {render: 0});
      t.identify(t.target()!);
      watch.stop();
      times.add(watch.elapsedMicroseconds);
      nodes = t.nodes.length;
      await _wait(20);
    }
    times.sort();
    _tree = {'nodes': nodes, 'medianUs': times[10], 'maxUs': times.last};
    router.pop();
    await _wait(1000);
  }

  Map<String, int> _tree = const {};
}
