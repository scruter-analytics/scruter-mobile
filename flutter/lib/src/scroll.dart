import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// What the primary scroll container shows (docs/MOBILE.md §3.7).
class ScrollInfo {
  const ScrollInfo({required this.depth, required this.from, required this.to, required this.content});

  /// 0–1: the bottom of the visible part.
  final double depth;

  /// 0–1: the visible part's top and bottom, for the 50 bands of time per block (§3.8).
  final double from;
  final double to;

  /// Content height, logical pixels.
  final double content;
}

/// The primary vertical scroll container (§3.7): the largest vertical [Scrollable] covering ≥ 50 % of the screen.
/// Depth = the bottom of what is visible ÷ the content height; lazy lists of a known length use item positions, their
/// content height being an estimate.
abstract final class Scrolls {
  /// A depth in % rounded to 5.
  static int percent(double depth) => (depth.clamp(0.0, 1.0) * 20).round() * 5;

  static ScrollableState? primary(Element root, Size screen) {
    ScrollableState? best;
    var bestArea = screen.width * screen.height / 2;
    void walk(Element e) {
      if (e.widget is Visibility && !(e.widget as Visibility).visible) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final box = e.renderObject;
        if (axisDirectionToAxis(s.axisDirection) == Axis.vertical && box is RenderBox && box.hasSize) {
          final area = box.size.width * box.size.height;
          if (area >= bestArea) {
            best = s;
            bestArea = area;
          }
        }
      }
      e.debugVisitOnstageChildren(walk);
    }

    walk(root);
    return best;
  }

  static ScrollInfo? measure(ScrollableState s) {
    final pos = s.position;
    if (!pos.hasContentDimensions || !pos.hasPixels || !pos.hasViewportDimension) return null;
    final viewport = pos.viewportDimension;
    final content = pos.maxScrollExtent + viewport;
    if (content <= 0) return null;
    final lazy = _lazyRange(s);
    if (lazy != null) {
      final (first, last, count) = lazy;
      final to = math.min((last + 1) / count, 1.0);
      return ScrollInfo(depth: to, from: first / count, to: to, content: content);
    }
    final top = pos.pixels.clamp(0.0, pos.maxScrollExtent);
    final bottom = top + viewport;
    return ScrollInfo(
      depth: math.min(bottom / content, 1.0),
      from: (top / content).clamp(0.0, 1.0),
      to: math.min(bottom / content, 1.0),
      content: content,
    );
  }

  /// `(first visible index, last visible index, item count)` of a viewport holding one lazy list of a known length.
  static (int, int, int)? _lazyRange(ScrollableState s) {
    final viewport = _viewportOf(s.context as Element);
    if (viewport == null || viewport.childCount != 1) return null;
    RenderSliver? sliver = viewport.firstChild;
    if (sliver is RenderSliverPadding) sliver = sliver.child;
    if (sliver is! RenderSliverMultiBoxAdaptor) return null;
    // ignore: invalid_use_of_protected_member
    final manager = sliver.childManager;
    if (manager is! SliverMultiBoxAdaptorElement) return null;
    final count = (manager.widget as SliverMultiBoxAdaptorWidget).delegate.estimatedChildCount;
    if (count == null || count <= 0 || sliver.firstChild == null) return null;
    final c = sliver.constraints;
    final top = c.scrollOffset;
    final bottom = top + c.remainingPaintExtent;
    int? first;
    var last = 0;
    for (var child = sliver.firstChild; child != null; child = sliver.childAfter(child)) {
      final start = sliver.childScrollOffset(child);
      if (start == null) continue;
      final end = start + (c.axis == Axis.vertical ? child.size.height : child.size.width);
      if (end <= top || start >= bottom) continue;
      final index = (child.parentData! as SliverMultiBoxAdaptorParentData).index ?? 0;
      first ??= index;
      last = index;
    }
    return first == null ? null : (first, last, count);
  }

  static RenderViewportBase? _viewportOf(Element e) {
    RenderViewportBase? found;
    var budget = 64;
    void walk(Element x) {
      if (found != null || budget-- <= 0) return;
      final r = x is RenderObjectElement ? x.renderObject : null;
      if (r is RenderViewportBase) {
        found = r;
        return;
      }
      x.visitChildren(walk);
    }

    walk(e);
    return found;
  }
}
