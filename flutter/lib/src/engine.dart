import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'bridge.dart';
import 'capture.dart';
import 'errors.dart';
import 'screen_view.dart';
import 'scroll.dart';
import 'taps.dart';
import 'text.dart';
import 'tree.dart';

/// The SDK's Dart layer (docs/MOBILE.md §17): the screens' engagement, scroll, taps, forms and team images, which only
/// the Flutter tree can tell, and the errors of the Dart side. Everything else is the native SDK's. Nothing here
/// schedules a frame on a user's phone; everything is light and runs at an event: a pointer, a scroll, a screen.
class ScruterEngine with WidgetsBindingObserver {
  ScruterEngine._();

  static ScruterEngine instance = ScruterEngine._();

  ScruterBridge? bridge;
  bool started = false;
  bool debug = false;
  bool _collecting = true;
  ScreenView? view;
  final Stopwatch _watch = Stopwatch()..start();
  final Random0 _random = Random0();

  /// Monotonic ms. Tests set it to the fake clock.
  @visibleForTesting
  static int Function()? testClock;

  int get now => testClock?.call() ?? _watch.elapsedMilliseconds;

  /// How many times a screen without a scroll container is measured again. Tests turn it off: its timers would outlive them.
  @visibleForTesting
  static int measureRetries = 3;

  ScruterErrors? errors;
  late final Taps taps = Taps(this);
  Timer? _measureTimer;
  Timer? _scrollTimer;
  Timer? _flingTimer;
  int _lastScrollMeasure = 0;
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  Route<dynamic>? _route;
  bool _background = false;
  Capture? _capture;
  FocusNode? _lastFocus;

  void log(String message) {
    if (debug) debugPrint('Scruter: $message');
  }

  // ------------------------------------------------------------------------------------------------ start

  Future<void> start({
    required String appId,
    required String sdkVersion,
    String? debugKey,
    bool debug = false,
    bool testBuild = false,
    String? endpoint,
    String? apiEndpoint,
  }) async {
    if (started) {
      log('Scruter.start called twice: ignored');
      return;
    }
    final binding = WidgetsFlutterBinding.ensureInitialized();
    started = true;
    this.debug = debug;
    bridge = ScruterBridge(_screenStarted);
    binding.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    FocusManager.instance.addListener(_focusChanged);
    errors = ScruterErrors(this)..install();
    await bridge!.call<void>('start', <String, Object?>{
      'appId': appId,
      // kDebugMode here, and the native SDK's own check: a release build that ships the key never uses it (§3.12).
      if (kDebugMode && debugKey != null) 'debugKey': debugKey,
      'debug': debug,
      'testBuild': testBuild,
      if (endpoint != null) 'endpoint': endpoint,
      if (apiEndpoint != null) 'apiEndpoint': apiEndpoint,
      'version': sdkVersion,
    });
  }

  @visibleForTesting
  static void resetForTests() {
    final e = instance;
    if (e.started) {
      WidgetsBinding.instance.removeObserver(e);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(e._pointer);
      FocusManager.instance.removeListener(e._focusChanged);
      e.errors?.uninstall();
      e.bridge?.detach();
      e._measureTimer?.cancel();
      e._scrollTimer?.cancel();
      e._flingTimer?.cancel();
      e.taps.reset();
      e._detachScroll();
      e._capture?.cancel();
    }
    instance = ScruterEngine._();
  }

  // ------------------------------------------------------------------------------------------------ screens

  /// `Scruter.screen`, or a route through [routeScreen].
  void screen(String raw, {bool forward = true}) {
    if (!started || !_collecting) return;
    final name = ScruterText.clean(raw, 120);
    if (name == null) return;
    final v = view;
    if (v != null && v.name == name && now - v.startMono < 1000) return;
    _route = null;
    _send(name, forward);
  }

  void routeScreen(String raw, Route<dynamic> route, {required bool forward}) {
    if (!started || !_collecting) return;
    final name = ScruterText.clean(raw, 120);
    if (name == null) return;
    _route = route;
    _send(name, forward);
  }

  void _send(String name, bool forward) {
    final v = view;
    if (v != null) _end(v, forward: forward, last: true);
    view = null;
    log('screen "$name"');
    bridge?.call<void>('screen', <String, Object?>{'name': name});
  }

  void _screenStarted(NativeScreen s) {
    _guard(() {
      final old = view;
      if (old != null) _end(old, forward: false, last: true);
      final v = ScreenView(
        name: s.name,
        session: s.session,
        analysed: s.analysed,
        startWall: s.startMs,
        startMono: now,
        number: _random.viewNumber(),
      );
      view = v;
      _background = false;
      _attachSoon(v, 0);
      if (s.capture) {
        _capture?.cancel();
        _capture = Capture(this, v, s.maxBytes, s.maxHeight)..schedule();
      }
    });
  }

  /// Measures the screen once it is on stage: size, scroll container, fields. The first frame of a route may be a few
  /// ms away: a timer, never a frame of ours.
  void _attachSoon(ScreenView v, int attempt) {
    _measureTimer?.cancel();
    _measureTimer = Timer(Duration(milliseconds: attempt == 0 ? 60 : 200), () {
      _guard(() {
        if (!identical(view, v)) return;
        final root = screenRoot();
        if (root == null) {
          if (attempt < 5) _attachSoon(v, attempt + 1);
          return;
        }
        _measure(v, root);
        // A heavy page takes more than a frame to be on stage: a container found later replaces the first answer.
        if (v.ch == 0 && attempt < measureRetries) _attachSoon(v, attempt + 1);
      });
    });
  }

  void _measure(ScreenView v, Element root) {
    final size = screenSize;
    v.vw = size.width.toInt();
    v.vh = size.height.toInt();
    _attachScroll(root, size);
    v.scrolled(now, _scrollable == null ? null : Scrolls.measure(_scrollable!), user: false);
    if (v.analysed) scanForms(v, root);
  }

  void scanForms(ScreenView v, Element root) {
    v.forms.scan(ScreenTree.build(root), () {
      view?.interact(now);
    });
    v.forms.focus(FocusManager.instance.primaryFocus, now);
  }

  Size get screenSize {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return Size.zero;
    final w = views.first;
    return w.physicalSize / w.devicePixelRatio;
  }

  /// The current screen's element: the route's page, else the topmost full-screen page on stage.
  Element? screenRoot() {
    final r = _route;
    if (r is ModalRoute && r.isActive) {
      final c = r.subtreeContext;
      if (c != null && c.mounted) return c as Element;
    }
    return WidgetsBinding.instance.rootElement;
  }

  /// A tap can land outside the page (a shell's bottom bar, a dialog above): the app's root then.
  Element? get appRoot => WidgetsBinding.instance.rootElement;

  void _end(ScreenView v, {required bool forward, required bool last}) {
    final t = now;
    taps.settle();
    if (v.visible) v.tick(t);
    if (forward) {
      v.forms.leaveForward(t);
    } else {
      v.forms.leave(t);
    }
    _report(v, last: last);
    if (last) {
      v.forms.dispose();
      _detachScroll();
    }
  }

  void _report(ScreenView v, {required bool last}) {
    final e = v.engagement(last: last);
    if (e != null) {
      bridge?.call<void>('screenEnd', <String, Object?>{'session': v.session, 'name': v.name, 'ms': e.$1, 'depth': e.$2});
    }
    state(v, last: last);
  }

  void state(ScreenView v, {required bool last}) {
    final s = v.state(last: last, now: now);
    if (s != null) bridge?.call<void>('analysed', <String, Object?>{'session': v.session, 'json': jsonEncode(s)});
  }

  // ------------------------------------------------------------------------------------------------ lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _guard(() {
      if (state == AppLifecycleState.resumed) {
        if (_background) {
          _background = false;
          view?.resume(now);
        }
      } else if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
        if (_background) return;
        _background = true;
        final v = view;
        if (v != null) {
          taps.settle();
          final t = now;
          v.forms.leave(t);
          v.suspend(t);
          _report(v, last: false);
        }
        bridge?.call<void>('flush');
      }
    });
  }

  // ------------------------------------------------------------------------------------------------ input

  void _pointer(PointerEvent e) {
    _guard(() {
      final v = view;
      if (v == null) return;
      if (e is PointerDownEvent) {
        _ensureScroll(v);
      } else if (e is PointerUpEvent) {
        // A fling goes on after the finger leaves.
        _flingTimer?.cancel();
        _flingTimer = Timer(const Duration(milliseconds: 800), () => _measureScroll(user: false));
      }
      taps.pointer(v, e);
    });
  }

  void _focusChanged() {
    _guard(() {
      final node = FocusManager.instance.primaryFocus;
      if (identical(node, _lastFocus)) return;
      _lastFocus = node;
      somethingHappened();
      final v = view;
      if (v == null || !v.analysed) return;
      v.interact(now);
      final root = screenRoot();
      if (root != null) v.forms.scan(ScreenTree.build(root), () => view?.interact(now));
      v.forms.focus(node, now);
    });
  }

  /// Something changed on screen: a tap waiting for its verdict is not dead.
  void somethingHappened() => taps.alive();

  /// After a tap: a choice changed, then a submit attempt once the app has validated (§3.9).
  void afterTap(ScreenView v, TreeNode target) {
    if (!v.analysed) return;
    final t = now;
    if (target.kind == 'choice' || target.isField && target.editable == null) {
      v.forms.choiceTapped(target.fieldElement ?? target.element, t);
    }
    if (target.kind == 'button') {
      Timer(const Duration(milliseconds: 500), () {
        _guard(() {
          if (!identical(view, v)) return;
          v.forms.submitAttempt();
        });
      });
    }
  }

  // ------------------------------------------------------------------------------------------------ scroll

  void _attachScroll(Element root, Size size) {
    final s = Scrolls.primary(root, size);
    final p = s == null || !s.mounted ? null : s.position;
    if (identical(p, _position)) {
      _scrollable = s;
      return;
    }
    _detachScroll();
    _scrollable = s;
    _position = p;
    p?.addListener(_scrolled);
  }

  void _detachScroll() {
    _position?.removeListener(_scrolled);
    _position = null;
    _scrollable = null;
  }

  void _ensureScroll(ScreenView v) {
    final s = _scrollable;
    if (s != null && s.mounted && identical(s.position, _position)) {
      if (v.ch == 0) _measureScroll(user: false);
      return;
    }
    final root = screenRoot();
    if (root == null) return;
    _attachScroll(root, screenSize);
    if (_scrollable != null) _measureScroll(user: false);
  }

  void _scrolled() {
    _guard(() {
      if (capturing) return;
      somethingHappened();
      final t = now;
      view?.interact(t);
      // Fires every frame of a scroll: measured at most 5 times a second, and once when it stops.
      if (t - _lastScrollMeasure > 200) {
        _measureScroll(user: true);
      } else {
        _scrollTimer?.cancel();
        _scrollTimer = Timer(const Duration(milliseconds: 220), () => _measureScroll(user: true));
      }
    });
  }

  void _measureScroll({required bool user}) {
    _guard(() {
      final v = view;
      final s = _scrollable;
      if (v == null || s == null || !s.mounted) return;
      _lastScrollMeasure = now;
      v.scrolled(now, Scrolls.measure(s), user: user);
    });
  }

  ScrollableState? get scrollable => _scrollable;

  bool get capturing => _capture?.running ?? false;

  void captureDone(Capture c) {
    if (identical(_capture, c)) _capture = null;
  }

  // ------------------------------------------------------------------------------------------------ the app's calls

  void fieldError(String key, int kind) => view?.forms.explicitError(key, kind);

  void formSent(String form) => view?.forms.sent(form, now);

  void setCollecting(bool on) {
    _collecting = on;
    if (on) return;
    final v = view;
    view = null;
    v?.forms.dispose();
    _detachScroll();
    _capture?.cancel();
    _capture = null;
    taps.reset();
  }

  /// The SDK never stands in the app's way: an internal failure is logged in debug mode and the item is lost.
  void _guard(void Function() f) {
    try {
      f();
    } catch (e) {
      log('internal error: $e');
    }
  }

  void guarded(void Function() f) => _guard(f);
}

/// `k`, the number of a screen view: random 1 … 2^53−1, in memory only.
class Random0 {
  final math.Random _r = math.Random();

  int viewNumber() {
    final hi = _r.nextInt(1 << 21);
    final lo = _r.nextInt(1 << 32);
    final v = hi * (1 << 32) + lo;
    return v == 0 ? 1 : v;
  }
}
