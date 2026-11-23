import 'package:flutter/material.dart';

import 'engine.dart';
import 'text.dart';

/// Counts the app's screens (docs/MOBILE.md §3.3): `navigatorObservers: [ScruterObserver()]` on a `MaterialApp`, a
/// `CupertinoApp` or a `Navigator`, `observers: [ScruterObserver()]` on a `GoRouter`. One instance per navigator.
///
/// The name is `RouteSettings.name`; with GoRouter, the route's `name`, else its path pattern (`/product/:id`), never
/// the parameters. A query or a fragment is dropped, and in a path-like name, a segment that is a value
/// (`/product/42`) becomes `:id`. Unnamed routes are not counted: dialogs and sheets stay part of the screen under
/// them unless they are named. [nameExtractor] names routes differently (return null to skip one).
class ScruterObserver extends NavigatorObserver {
  ScruterObserver({this.nameExtractor});

  final String? Function(RouteSettings settings)? nameExtractor;

  final List<Route<dynamic>> _stack = [];
  Route<dynamic>? _shown;
  bool _forward = false;
  bool _scheduled = false;

  String? _nameOf(Route<dynamic> route) {
    final settings = route.settings;
    final extractor = nameExtractor;
    final raw = extractor != null ? extractor(settings) : settings.name;
    if (raw == null) return null;
    final name = extractor != null ? raw : ScruterText.routeName(raw);
    return name.trim().isEmpty ? null : name;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed(forward: true);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed(forward: false);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed(forward: false);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      if (i >= 0) {
        _stack[i] = newRoute;
      } else {
        _stack.add(newRoute);
      }
    } else if (i >= 0) {
      _stack.removeAt(i);
    }
    _changed(forward: true);
  }

  /// One navigation can notify several times (a `Navigator.pages` update): the screen is settled once, right after.
  void _changed({required bool forward}) {
    _forward = _scheduled ? _forward || forward : forward;
    ScruterEngine.instance.somethingHappened();
    if (_scheduled) return;
    _scheduled = true;
    Future<void>.microtask(_settle);
  }

  void _settle() {
    _scheduled = false;
    if (_stack.isEmpty) return;
    final top = _stack.last;
    if (identical(top, _shown)) return;
    final name = _nameOf(top);
    if (name == null) {
      // A dialog stays part of the screen under it; an unnamed page leaves it.
      if (top is! PopupRoute) _shown = top;
      ScruterEngine.instance.log('name this screen: a route has no name (RouteSettings.name, or Scruter.screen)');
      return;
    }
    _shown = top;
    ScruterEngine.instance.routeScreen(name, top, forward: _forward);
  }
}
