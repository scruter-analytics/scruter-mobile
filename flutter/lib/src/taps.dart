import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'screen_view.dart';
import 'tree.dart';

/// Taps, dead taps and rage taps through the hit test (docs/MOBILE.md §3.6), in sessions of the Advanced analytics sample.
/// The pointer route is global and only watches: it never joins a gesture arena. The target and its identity are
/// computed when the finger lifts, before the app reacts (the screen as the user saw it).
/// - Dead: a tap on a non-interactive target after which nothing happens within 1 s: no screen change, scroll, focus
///   change, new route, nor different element tree.
/// - Rage: the third tap within 1 s inside a 24-point circle opens a burst; that tap carries the flag.
class Taps {
  Taps(this._engine);

  /// A press longer than this is not a tap (Android: twice the long-press timeout, as the native SDKs).
  static const _maxPressMs = 800;

  final ScruterEngine _engine;
  int? _pointer;
  Offset _down = Offset.zero;
  int _downAt = 0;
  bool _moved = true;
  final List<(double, double, int)> _recent = [];
  bool _burst = false;
  _DeadWatch? _watch;

  void reset() {
    _watch?.cancel();
    _watch = null;
    _pointer = null;
  }

  void pointer(ScreenView v, PointerEvent e) {
    if (e is PointerDownEvent) {
      if (_pointer != null) {
        _moved = true;
        return;
      }
      _pointer = e.pointer;
      _down = e.position;
      _downAt = _engine.now;
      _moved = false;
    } else if (e.pointer != _pointer) {
      return;
    } else if (e is PointerMoveEvent) {
      if (!_moved && (e.position - _down).distance > kTouchSlop) _moved = true;
    } else if (e is PointerCancelEvent) {
      _pointer = null;
    } else if (e is PointerUpEvent) {
      _pointer = null;
      final t = _engine.now;
      if (!_moved && t - _downAt < _maxPressMs) {
        v.interact(t);
        if (v.analysed) _tap(v, e, t);
      }
    }
  }

  void _tap(ScreenView v, PointerUpEvent e, int t) {
    final began = Stopwatch()..start();
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, e.position, e.viewId);
    final hit = <Object, int>{};
    var rank = 0;
    var link = false;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject) {
        hit[target] = rank++;
      } else if (target is TextSpan && target.recognizer != null) {
        link = true;
      }
    }
    final root = _engine.screenRoot();
    if (root == null) return;
    var tree = ScreenTree.build(root, hit: hit);
    // Outside the page: a shell's bar, a dialog above it.
    if (tree.hitNode == null || identical(tree.hitNode, tree.root)) {
      final app = _engine.appRoot;
      if (app != null && !identical(app, root)) {
        final whole = ScreenTree.build(app, hit: hit);
        if (whole.hitNode != null && !identical(whole.hitNode, whole.root)) tree = whole;
      }
    }
    final target = tree.target();
    if (target == null) return;
    if (link) {
      target.interactive = true;
      target.kind = 'link';
    }
    final (selector, index) = tree.identify(target);
    final (px, py) = _inside(target, e.position);
    final ms = t - v.startMono;
    final flags = _rage(e.position.dx, e.position.dy, t) ? 2 : 0;
    // `web` exists only in a team phone's tree (docs/MOBILE.md §3.5): a tap on a web view stays `media`.
    final kind = target.kind == 'web' ? 'media' : target.kind;
    settle();
    if (target.interactive) {
      v.tap(selector, index, kind, px, py, ms, flags);
      _full(v);
    } else {
      _watch = _DeadWatch(this, v, selector, index, kind, px, py, ms, flags, tree.root.element);
    }
    _engine.afterTap(v, target);
    if (_engine.debug) _engine.log('tap $selector: ${began.elapsedMicroseconds} µs, ${tree.nodes.length} elements');
  }

  void _full(ScreenView v) {
    if (v.tapsSinceState >= ScreenView.tapsPerState) _engine.state(v, last: false);
  }

  static (int, int) _inside(TreeNode n, Offset global) {
    final r = n.element.renderObject;
    if (r is RenderBox && r.hasSize && r.size.width > 0 && r.size.height > 0) {
      final local = r.globalToLocal(global);
      return ((local.dx * 100 / r.size.width).round(), (local.dy * 100 / r.size.height).round());
    }
    return (50, 50);
  }

  /// §3.6: the third tap within 1 s inside a 24-point circle; one flag per burst.
  bool _rage(double x, double y, int t) {
    _recent.removeWhere((r) => t - r.$3 > 1000);
    _recent.add((x, y, t));
    while (_recent.length > 3) {
      _recent.removeAt(0);
    }
    final close = _recent.length >= 3 &&
        _recent.every((r) => (Offset(r.$1, r.$2) - Offset(x, y)).distance <= 24);
    if (!close) {
      _burst = false;
      return false;
    }
    if (_burst) return false;
    _burst = true;
    return true;
  }

  /// Something happened on screen: a pending tap is not dead.
  void alive() => _watch?.settle(dead: false);

  /// Settles a pending tap now (the screen view ends, the app goes to the background).
  void settle() => _watch?.settle(dead: false);
}

class _DeadWatch {
  _DeadWatch(this._taps, this._view, this._selector, this._index, this._kind, this._x, this._y, this._ms, this._flags, Element root)
      : _root = root,
        _print = ScreenTree.fingerprint(root) {
    _timer = Timer(const Duration(seconds: 1), () {
      _taps._engine.guarded(() => settle(dead: !_root.mounted ? false : ScreenTree.fingerprint(_root) == _print));
    });
  }

  final Taps _taps;
  final ScreenView _view;
  final String _selector;
  final int _index;
  final String _kind;
  final int _x;
  final int _y;
  final int _ms;
  final int _flags;
  final Element _root;
  final int _print;
  late final Timer _timer;
  bool _done = false;

  void cancel() {
    _done = true;
    _timer.cancel();
  }

  void settle({required bool dead}) {
    if (_done) return;
    _done = true;
    _timer.cancel();
    if (identical(_taps._watch, this)) _taps._watch = null;
    _view.tap(_selector, _index, _kind, _x, _y, _ms, _flags | (dead ? 1 : 0));
    _taps._full(_view);
  }
}
