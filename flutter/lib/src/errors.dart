import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'engine.dart';
import 'stack.dart';
import 'text.dart';

/// Uncaught Dart errors (docs/MOBILE.md §3.10): `FlutterError.onError` and `PlatformDispatcher.instance.onError`,
/// chained: other reporters keep working. Flutter's root isolate survives its errors, so they are `nonfatal`; an app
/// that treats one as a crash says so with `Scruter.reportError(fatal: true)`.
class ScruterErrors {
  ScruterErrors(this._engine);

  final ScruterEngine _engine;
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  FlutterExceptionHandler? _flutter;
  ErrorCallback? _platform;
  final Map<String, int> _recent = {};

  void install() {
    _wrap();
    // An app that sets its own handlers after `start` without chaining would cut this one off.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_flutter != null) _wrap();
    });
  }

  void _wrap() {
    if (!identical(FlutterError.onError, _flutter)) {
      final previous = FlutterError.onError;
      _previousFlutter = previous;
      void handler(FlutterErrorDetails d) {
        if (!d.silent) report(d.exception, d.stack, fatal: false);
        previous?.call(d);
      }

      _flutter = handler;
      FlutterError.onError = handler;
    }
    final dispatcher = PlatformDispatcher.instance;
    if (!identical(dispatcher.onError, _platform)) {
      final previous = dispatcher.onError;
      _previousPlatform = previous;
      bool handler(Object e, StackTrace s) {
        report(e, s, fatal: false);
        return previous?.call(e, s) ?? false;
      }

      _platform = handler;
      dispatcher.onError = handler;
    }
  }

  void uninstall() {
    if (identical(FlutterError.onError, _flutter)) FlutterError.onError = _previousFlutter;
    if (identical(PlatformDispatcher.instance.onError, _platform)) PlatformDispatcher.instance.onError = _previousPlatform;
    _flutter = null;
    _platform = null;
  }

  /// An error of the wrapper's runtime goes to the native SDK, which adds the screen, the breadcrumbs and the session.
  /// The same error is reported once per second: a widget failing in `build` fires at every frame, and each report
  /// costs a parse of the stack and a channel call on the UI thread.
  void report(Object error, StackTrace? stack, {required bool fatal}) {
    _engine.guarded(() {
      final type = ScruterText.typeName(error.runtimeType.toString()) ?? 'Error';
      final parsed = DartStack.parse(stack ?? StackTrace.empty);
      final key = '$type|${parsed.frames.isEmpty ? '' : parsed.frames.first}';
      final t = _engine.now;
      final last = _recent[key];
      if (last != null && t - last < 1000 && !fatal) return;
      if (_recent.length > 50) _recent.clear();
      _recent[key] = t;
      final reason = ScruterText.clean(_firstLine(error), 200) ?? '';
      _engine.bridge?.call<void>('reportError', <String, Object?>{
        'fatal': fatal,
        'type': type,
        'reason': reason,
        'frames': parsed.frames,
        if (parsed.buildId != null) 'buildId': parsed.buildId,
        'images': parsed.images,
      });
    });
  }

  static String _firstLine(Object error) {
    final s = error is FlutterError ? error.message : error.toString();
    final i = s.indexOf('\n');
    return i < 0 ? s : s.substring(0, i);
  }
}
