import 'dart:async';

import 'engine.dart';

/// The version batches name (`flutter/1.0.0`): the package's.
const scruterVersion = '1.0.0';

/// The kind of a form field's error (docs/MOBILE.md §3.9).
enum ScruterFieldError {
  required(1),
  format(2),
  refused(4),
  invalid(8);

  const ScruterFieldError(this.bit);

  final int bit;
}

/// Scruter Analytics: start it once, before `runApp`, and add `ScruterObserver` to the app's navigator:
///
/// ```dart
/// void main() async {
///   await Scruter.start(appId: 'ATMONA02');
///   runApp(MaterialApp(navigatorObservers: [ScruterObserver()], home: const Home()));
/// }
/// ```
///
/// Every call returns at once, never throws, and is a no-op before [start].
abstract final class Scruter {
  static ScruterEngine get _e => ScruterEngine.instance;

  /// Starts the SDK (docs/MOBILE.md §3.1). [appId] is the "App identifier" of App settings › SDK. [debugKey] makes
  /// a debug build a team phone and is used only with `kDebugMode`; [debug] logs to the console; [testBuild] marks a
  /// build given to testers, which the app's settings can exclude; [endpoint] and [apiEndpoint] are for tests.
  static Future<void> start({
    required String appId,
    String? debugKey,
    bool debug = false,
    bool testBuild = false,
    String? endpoint,
    String? apiEndpoint,
  }) =>
      _e.start(
        appId: appId,
        sdkVersion: scruterVersion,
        debugKey: debugKey,
        debug: debug,
        testBuild: testBuild,
        endpoint: endpoint,
        apiEndpoint: apiEndpoint,
      );

  /// Counts a screen view of [name] (≤ 120 characters), for screens the observer does not see: tabs, pages of a
  /// `PageView`, an app without named routes.
  static void screen(String name) => _e.screen(name);

  /// Sends the custom event [name] (docs/MOBILE.md §3.4) with up to 30 [props] (strings, numbers, booleans) and a
  /// [revenue] in major units with its ISO 4217 [currency] (no currency, no revenue). Never put personal data in a name
  /// or a property.
  static void track(String name, {Map<String, Object?>? props, double? revenue, String? currency}) {
    if (!_e.started) return;
    final clean = <String, Object?>{};
    props?.forEach((k, v) {
      if (v is String || v is num || v is bool) {
        clean[k] = v;
      } else if (v != null) {
        _e.log('track "$name": property "$k" is not a string, number or boolean: dropped');
      }
    });
    _e.bridge?.call<void>('track', <String, Object?>{
      'name': name,
      if (clean.isNotEmpty) 'props': clean,
      if (revenue != null) 'revenue': revenue,
      if (currency != null) 'currency': currency,
    });
  }

  /// Reports an error shown on a form field, when `InputDecoration` does not show it ([field]: its identifier or
  /// autofill type).
  static void fieldError(String field, ScruterFieldError kind) => _e.fieldError(field, kind.bit);

  /// Marks the form [form] as sent, when leaving the screen forward does not say it.
  static void formSent(String form) => _e.formSent(form);

  /// Reports a caught error: a `nonfatal` report, or a `crash` of the session with [fatal]. Never put personal data in
  /// an error's message: only its first line, cut to 200 characters and masked by the server, is sent.
  static void reportError(Object error, StackTrace? stack, {bool fatal = false}) {
    _e.errors?.report(error, stack, fatal: fatal);
  }

  /// The user objects to audience measurement (docs/MOBILE.md §2.3): wire it to the app's "Audience measurement" setting.
  /// Nothing is sent any more; the queue, the daily identifier and the install day are deleted.
  static void optOut() {
    if (!_e.started) return;
    _e.setCollecting(false);
    _e.bridge?.call<void>('optOut');
  }

  /// Measurement again, as a new install without an install day.
  static void optIn() {
    if (!_e.started) return;
    _e.setCollecting(true);
    _e.bridge?.call<void>('optIn');
  }

  /// Whether the user opted out.
  static Future<bool> get isOptedOut async => await _e.bridge?.call<bool>('isOptedOut') ?? false;

  /// Stops measurement on this phone (the team's own test phones, "Test devices").
  static void ignoreThisDevice([bool ignore = true]) {
    if (!_e.started) return;
    _e.setCollecting(!ignore);
    _e.bridge?.call<void>('ignoreThisDevice', <String, Object?>{'ignore': ignore});
  }

  /// Whether [ignoreThisDevice] is on.
  static Future<bool> get isDeviceIgnored async => await _e.bridge?.call<bool>('isDeviceIgnored') ?? false;

  /// The app was opened from a notification, when the SDK cannot see it by itself (no Firebase Cloud Messaging
  /// intent, no `UNUserNotificationCenter` delegate).
  static void openedFromNotification() {
    _e.bridge?.call<void>('openedFromNotification');
  }

  /// Forwards a link that opened the app, for what the plugin does not see itself: an app that handles its links with
  /// a `UISceneDelegate`. Only the link's host, path and `utm_*` values leave the phone.
  static void handleLink(String url) {
    _e.bridge?.call<void>('link', <String, Object?>{'url': url});
  }

  /// Sends what waits now.
  static void flush() {
    _e.bridge?.call<void>('flush');
  }

  /// Whether this phone is one of the team's phones (it takes the screen images of Screen analysis).
  static Future<bool> get isTeamPhone async => await _e.bridge?.call<bool>('isTeamPhone') ?? false;

  /// Removes this phone from the team's phones.
  static void leaveTeamMode() {
    _e.bridge?.call<void>('leaveTeamMode');
  }
}
