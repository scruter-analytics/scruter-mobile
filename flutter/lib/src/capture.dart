import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'engine.dart';
import 'screen_view.dart';
import 'tree.dart';

/// A team phone's image of one screen (docs/MOBILE.md §3.11–§3.12), from the Flutter layer: only on team phones, never
/// on a user's. When the screen is idle (1 s after its appearance, no animation running, no activity indicator), the
/// page is painted to an image: the full content of its primary scroll container, scrolled step by step and stitched,
/// ≤ the server's height, then scrolled back, at the device scale ≤ 2×. Text inputs, platform views and `ScruterMask`
/// elements are filled with an opaque rectangle in each strip's pixels, in Dart, before they go to the native layer
/// that encodes the JPEG; the element tree marks them `m: 1`, without label. Only Flutter's own layers are drawn: never
/// the keyboard, a system dialog or another app. Memory: the native image ≤ 40 MB (10 M pixels) + one strip twice
/// (≈ 10 MB), under the 60 MB of §3.18; a taller screen is taken below 2×.
class Capture {
  Capture(this._engine, this._view, this._maxBytes, this._maxHeight);

  static const _maxPixels = 10 * 1000 * 1000;
  static const _maxNodes = 2000;
  static const _maskColor = 0xFFBDBDBD; // opaque, RGBA in memory on little-endian phones

  final ScruterEngine _engine;
  final ScreenView _view;
  final int _maxBytes;
  final int _maxHeight;
  bool running = false;
  bool _cancelled = false;
  Timer? _timer;
  int _waited = 0;
  int _quiet = 0;

  void schedule() {
    _timer = Timer(const Duration(seconds: 1), _waitIdle);
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
  }

  bool get _current => !_cancelled && identical(_engine.view, _view) && _view.visible;

  void _waitIdle() {
    if (!_current) return _stop();
    final root = _engine.screenRoot();
    if (root == null) return _stop();
    final scheduler = SchedulerBinding.instance;
    final busy = scheduler.transientCallbackCount > 0 || scheduler.hasScheduledFrame || _spinning(root);
    _quiet = busy ? 0 : _quiet + 250;
    if (_quiet < 500) {
      _waited += 250;
      if (_waited > 10000) return _stop();
      _timer = Timer(const Duration(milliseconds: 250), _waitIdle);
      return;
    }
    unawaited(_shoot(root).catchError((Object e) {
      _engine.log('screen image failed: $e');
      _engine.bridge?.call<void>('imageCancel');
    }).whenComplete(_stop));
  }

  void _stop() {
    running = false;
    _engine.captureDone(this);
  }

  static bool _spinning(Element root) {
    var found = false;
    void walk(Element e) {
      if (found) return;
      final w = e.widget;
      if (w is ProgressIndicator && w.value == null || w is CupertinoActivityIndicator) {
        found = true;
        return;
      }
      e.debugVisitOnstageChildren(walk);
    }

    walk(root);
    return found;
  }

  static RenderRepaintBoundary? _boundary(Element root) {
    final r = root.renderObject;
    if (r is RenderRepaintBoundary) return r;
    // The app's root, or a page without a route: the topmost page on stage.
    RenderRepaintBoundary? found;
    void walk(Element x) {
      final o = x is RenderObjectElement ? x.renderObject : null;
      if (o is RenderRepaintBoundary && o.hasSize && o.size.height > 100 && o.size.width > 100) found = o;
      x.debugVisitOnstageChildren(walk);
    }

    walk(root);
    return found;
  }

  Future<void> _shoot(Element root) async {
    final boundary = _boundary(root);
    if (boundary == null || !boundary.hasSize) return;
    running = true;
    final page = boundary.size;
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final s = _engine.scrollable;
    final pos = s != null && s.mounted ? s.position : null;
    final box = s?.context.findRenderObject();
    var top = 0.0;
    var viewport = page.height;
    if (pos != null && box is RenderBox) {
      top = box.localToGlobal(Offset.zero, ancestor: boundary).dy;
      viewport = box.size.height;
    }
    final below = math.max(0.0, page.height - top - viewport);
    final scrolls = pos != null && pos.maxScrollExtent > 1;
    final maxPoints = _maxHeight.toDouble();
    final estimate = math.min(maxPoints, scrolls ? top + pos.maxScrollExtent + viewport + below : page.height);
    var scale = math.min(2.0, dpr);
    final pixelsAt1 = page.width * estimate;
    if (pixelsAt1 * scale * scale > _maxPixels) scale = math.sqrt(_maxPixels / pixelsAt1);
    final width = (page.width * scale).floor();
    final maxRows = math.min(_maxPixels ~/ width, (maxPoints * scale).floor());
    await _engine.bridge?.call<void>('imageBegin', <String, Object?>{'width': width, 'rows': maxRows});

    final nodes = <String, Map<String, Object?>>{};
    final initial = pos?.pixels ?? 0;
    var rows = 0;
    var offset = 0.0;
    try {
      if (scrolls && initial != 0) await _jump(pos, 0);
      if (!_current) return _abort();
      // First strip: everything above the container, and what the container shows.
      var strip = await _strip(boundary, scale, width, root, offset, top, viewport, nodes, rows,
          scrolls ? Rect.fromLTRB(0, 0, page.width, top + viewport) : null);
      final firstRows = ((top + viewport) * scale).round();
      await _send(strip.$1, strip.$2, width, 0, firstRows, rows);
      rows += firstRows;
      if (scrolls) {
        while (_current) {
          final content = pos.maxScrollExtent + viewport;
          final limit = math.min(content, maxPoints - top - below);
          if (offset + viewport >= limit - 0.5) break;
          final step = math.min(viewport - _pinned(s!), limit - offset - viewport);
          if (step < 1) break;
          await _jump(pos, offset + step);
          final moved = pos.pixels - offset;
          if (moved < 1) break;
          offset = pos.pixels;
          final wanted = (moved * scale).round();
          final room = maxRows - rows - (below * scale).round();
          if (room <= 0) break;
          final take = math.min(wanted, room);
          strip = await _strip(boundary, scale, width, root, offset, top, viewport, nodes, rows - ((top + viewport - moved) * scale).round(), Rect.fromLTRB(0, top, page.width, top + viewport));
          await _send(strip.$1, strip.$2, width, ((top + viewport) * scale).round() - wanted, take, rows);
          rows += take;
        }
      }
      if (!_current) return _abort();
      if (below > 0.5) {
        strip = await _strip(boundary, scale, width, root, offset, top, viewport, nodes, rows - ((top + viewport) * scale).round(), Rect.fromLTRB(0, top + viewport, page.width, page.height));
        final take = math.min((below * scale).round(), maxRows - rows);
        await _send(strip.$1, strip.$2, width, ((top + viewport) * scale).round(), take, rows);
        rows += take;
      }
    } finally {
      if (scrolls && pos.hasPixels && pos.pixels != initial) pos.jumpTo(initial);
    }
    final tree = jsonEncode(<String, Object?>{'v': 1, 'nodes': nodes.values.take(_maxNodes).toList()});
    await _engine.bridge?.call<void>('imageFinish', <String, Object?>{
      'screen': _view.name,
      'tree': tree,
      'rows': rows,
      'scale': scale,
      'maxBytes': _maxBytes,
    });
    _engine.log('screen image of "${_view.name}": $width × $rows, ${nodes.length} elements');
  }

  void _abort() {
    _engine.bridge?.call<void>('imageCancel');
  }

  /// What a pinned header takes of the viewport in every strip.
  static double _pinned(ScrollableState s) {
    RenderViewportBase? v;
    void walk(Element e) {
      if (v != null) return;
      final r = e is RenderObjectElement ? e.renderObject : null;
      if (r is RenderViewportBase) {
        v = r;
        return;
      }
      e.visitChildren(walk);
    }

    walk(s.context as Element);
    final viewport = v;
    if (viewport == null) return 0;
    var pinned = 0.0;
    for (var c = viewport.firstChild; c != null; c = viewport.childAfter(c)) {
      if (c is RenderSliverPinnedPersistentHeader) pinned += c.geometry?.maxPaintExtent ?? 0;
    }
    return pinned;
  }

  Future<void> _jump(ScrollPosition pos, double to) async {
    pos.jumpTo(to);
    SchedulerBinding.instance.ensureVisualUpdate();
    await SchedulerBinding.instance.endOfFrame;
    // Lazy lists build their new items in that frame, their images a little later.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    SchedulerBinding.instance.ensureVisualUpdate();
    await SchedulerBinding.instance.endOfFrame;
  }

  /// Paints the page, fills the masks in its pixels, adds the nodes seen. [baseY]: image row of the strip's row 0.
  Future<(Uint8List, int)> _strip(
    RenderRepaintBoundary boundary,
    double scale,
    int width,
    Element root,
    double offset,
    double top,
    double viewport,
    Map<String, Map<String, Object?>> nodes,
    int baseY,
    Rect? only,
  ) async {
    final image = await boundary.toImage(pixelRatio: scale);
    final ByteData? data;
    final height = image.height;
    final imageWidth = image.width;
    try {
      data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
    if (data == null) throw StateError('no pixels');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final tree = ScreenTree.build(root, labels: true);
    final pixels = bytes.buffer.asUint32List(bytes.offsetInBytes, bytes.lengthInBytes >> 2);
    for (final n in tree.nodes) {
      final r = n.element.renderObject;
      if (r is! RenderBox || !r.hasSize || !r.attached) continue;
      final Rect frame;
      try {
        frame = MatrixUtils.transformRect(r.getTransformTo(boundary), Offset.zero & r.size);
      } catch (_) {
        continue;
      }
      final visible = frame.intersect(Offset.zero & boundary.size);
      if (visible.isEmpty) continue;
      if (n.masked) _fill(pixels, imageWidth, height, frame, scale);
      if (only != null && !only.overlaps(frame)) continue;
      if (n.ignored) continue;
      if (nodes.length >= _maxNodes) continue;
      final (selector, index) = tree.identify(n);
      final key = '$selector#$index';
      if (nodes.containsKey(key)) continue;
      final m = n.masked;
      nodes[key] = <String, Object?>{
        's': selector,
        'i': index,
        'k': n.kind,
        'x': (frame.left * scale).round().clamp(0, 20000),
        'y': (baseY + frame.top * scale).round().clamp(0, 20000),
        'w': (frame.width * scale).round().clamp(0, 20000),
        'h': (frame.height * scale).round().clamp(0, 20000),
        if (!m && n.label != null) 'l': n.label,
        if (m) 'm': 1,
      };
    }
    return (bytes, imageWidth);
  }

  static void _fill(Uint32List pixels, int width, int height, Rect frame, double scale) {
    final left = (frame.left * scale).floor().clamp(0, width);
    final right = (frame.right * scale).ceil().clamp(0, width);
    final top = (frame.top * scale).floor().clamp(0, height);
    final bottom = (frame.bottom * scale).ceil().clamp(0, height);
    for (var y = top; y < bottom; y++) {
      pixels.fillRange(y * width + left, y * width + right, _maskColor);
    }
  }

  /// Sends [count] rows of [strip] from its row [from] to the image's row [at].
  Future<void> _send(Uint8List strip, int stripWidth, int width, int from, int count, int at) async {
    final rows = strip.lengthInBytes ~/ (stripWidth * 4);
    final n = math.min(count, rows - from);
    if (n <= 0) return;
    final w = math.min(stripWidth, width);
    final out = Uint8List(w * n * 4);
    for (var y = 0; y < n; y++) {
      final src = (from + y) * stripWidth * 4;
      out.setRange(y * w * 4, (y + 1) * w * 4, strip, src);
    }
    await _engine.bridge?.call<void>('imageStrip', <String, Object?>{'y': at, 'rows': n, 'width': w, 'rgba': out});
  }
}
