import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scruter.dart' show scruterVersion;

/// Where the CMP stands (docs/CMP-MOBILE.md §3.1).
enum ScruterConsentState {
  /// A valid stored choice for the current configuration.
  ready,

  /// The sheet must show: no choice yet, or the banner asks again.
  needsDecision,

  /// No configuration could be fetched and none is cached: every optional purpose stays denied.
  unavailable,
}

/// When the sheet shows: by itself once the app is on screen, or where the app calls [ScruterCMP.showIfNeeded].
enum ScruterPresentation { automatic, manual }

/// Apple's App Tracking Transparency status; [unsupported] on Android, which has no such prompt.
enum ScruterTrackingStatus { notDetermined, restricted, denied, authorized, unsupported }

/// A Google Consent Mode signal's value (§3.7).
enum ScruterConsentStatus { granted, denied }

/// The purposes every Scruter banner may have; a banner adds its own keys (`isGranted('crash_reports')`).
abstract final class ScruterPurpose {
  static const necessary = 'necessary';
  static const analytics = 'analytics';
  static const advertising = 'advertising';
  static const personalization = 'personalization';
  static const embeddedContent = 'embedded_content';
  static const socialMedia = 'social_media';
  static const functional = 'functional';
}

/// The Google Consent Mode v2 signals, named as Firebase names them.
const scruterConsentSignals = [
  'ad_storage',
  'ad_user_data',
  'ad_personalization',
  'analytics_storage',
  'functionality_storage',
  'personalization_storage',
  'security_storage',
];

/// A visitor's choice.
@immutable
class ScruterChoice {
  const ScruterChoice({required this.consentId, required this.decidedAt, required this.granted, required this.denied});

  static ScruterChoice? _from(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['consentId'];
    if (id is! String) return null;
    return ScruterChoice(
      consentId: id,
      decidedAt: DateTime.fromMillisecondsSinceEpoch((raw['decidedAt'] as num?)?.toInt() ?? 0, isUtc: true),
      granted: List<String>.unmodifiable((raw['granted'] as List?)?.cast<String>() ?? const <String>[]),
      denied: List<String>.unmodifiable((raw['denied'] as List?)?.cast<String>() ?? const <String>[]),
    );
  }

  /// The receipt the visitor can give you to find their proofs (`cns_…`).
  final String consentId;
  final DateTime decidedAt;

  /// The purposes granted, the required ones included.
  final List<String> granted;

  /// The optional purposes refused.
  final List<String> denied;

  bool isGranted(String purpose) => purpose == ScruterPurpose.necessary || granted.contains(purpose);

  String get _key => '$consentId|${decidedAt.millisecondsSinceEpoch}|${granted.join(',')}';

  @override
  bool operator ==(Object other) => other is ScruterChoice && other._key == _key && listEquals(other.denied, denied);

  @override
  int get hashCode => _key.hashCode;

  @override
  String toString() => 'ScruterChoice($consentId, granted: $granted, denied: $denied)';
}

/// Stops a [ScruterCMP.whenReady] or [ScruterCMP.onChange] callback.
class ScruterSubscription {
  ScruterSubscription._(this._cancel);

  final void Function() _cancel;

  void cancel() => _cancel();
}

/// The Dart side of Scruter CMP: the state the native module last told, and the app's callbacks. One per isolate: a hot
/// restart makes a new one, and the native module, which runs once per process, tells only the newest.
class _Cmp {
  _Cmp() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        final a = call.arguments as Map<Object?, Object?>;
        _received(a['snapshot'] as Map<Object?, Object?>? ?? const {}, a['newChoice'] == true);
      }
    });
  }

  static const channel = MethodChannel('net.scruter/cmp');

  bool started = false;
  bool debug = false;
  bool forceShow = false;
  String? language;
  Map<Object?, Object?> snapshot = const {};
  ScruterChoice? current;
  bool hadChoice = false;
  final ready = <void Function(ScruterChoice)>[];
  final changes = <void Function(ScruterChoice)>[];
  final stream = StreamController<ScruterChoice>.broadcast(sync: true);

  void log(String m) {
    if (debug) debugPrint('ScruterCMP: $m');
  }

  Future<T?> call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      log('$method failed: ${e.code}');
      return null;
    }
  }

  void each(List<void Function(ScruterChoice)> list, ScruterChoice c) {
    for (final f in List.of(list)) {
      try {
        f(c);
      } catch (e, s) {
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s, library: 'scruter_flutter', context: ErrorDescription('in a callback of ScruterCMP')));
      }
    }
  }

  /// A new snapshot: the ready queue once a choice exists, the change callbacks for every later one.
  void _received(Map<Object?, Object?> s, bool newChoice) {
    snapshot = s;
    final next = ScruterChoice._from(s['choice']);
    final changed = next?._key != current?._key;
    current = next;
    if (next == null) return;
    if (ready.isNotEmpty) {
      final now = List.of(ready);
      ready.clear();
      each(now, next);
    }
    if (newChoice && changed) {
      log('choice ${next.consentId}: ${next.granted.join(', ')}');
      if (hadChoice) each(changes, next);
      stream.add(next);
    }
    hadChoice = true;
  }
}

/// Scruter CMP for Flutter (docs/CMP-MOBILE.md §3.4): the native consent sheet of iOS and Android, shown over the app's
/// navigator; the choice kept in the app's own storage, its proofs and their queue, all in the native modules. Take it
/// with `scruter: { cmp: true }` in the app's pubspec.yaml, start it once before `runApp`, then gate the app's SDKs:
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await ScruterCMP.start(appId: 'ATMONA02');
///   ScruterCMP.whenReady(applyConsent);
///   ScruterCMP.onChange(applyConsent);
///   runApp(const AtelierMonaApp());
/// }
/// ```
///
/// Until a choice exists, every optional purpose is denied. Before [start], every call is a no-op that grants nothing.
abstract final class ScruterCMP {
  static _Cmp _c = _Cmp();

  /// Tests only: a new isolate's state, as after a hot restart.
  @visibleForTesting
  static void resetForTest() {
    _c.stream.close();
    _c = _Cmp();
  }

  /// Starts the CMP once; returns once the native module read the stored choice: [isGranted] answers from the next
  /// line. A hot restart starts nothing again (the native module runs once per process). [endpoint] is for tests.
  static Future<void> start({
    required String appId,
    ScruterPresentation presentation = ScruterPresentation.automatic,
    String? endpoint,
  }) async {
    final c = _c;
    if (c.started) {
      c.log('start called twice: ignored');
      return;
    }
    c.started = true;
    final s = await c.call<Map<Object?, Object?>>('start', <String, Object?>{
      'appId': appId,
      'manual': presentation == ScruterPresentation.manual,
      'endpoint': endpoint,
      'version': scruterVersion,
      'forceShow': c.forceShow,
      'debug': c.debug,
      'language': c.language,
    });
    if (s == null) {
      c.started = false;
      debugPrint(
          'ScruterCMP: the native module is not in this app: add `scruter: { cmp: true }` to pubspec.yaml, then rebuild');
      return;
    }
    c._received(s, false);
    c.log('started: ${state.name}');
  }

  static List<String> get _granted => (_c.snapshot['granted'] as List?)?.cast<String>() ?? const [];

  /// Whether [purpose] is granted now: synchronous, `false` for every optional purpose until a choice exists.
  static bool isGranted(String purpose) => _granted.contains(purpose);

  static ScruterConsentState get state => switch (_c.snapshot['state']) {
        'ready' => ScruterConsentState.ready,
        'needsDecision' => ScruterConsentState.needsDecision,
        _ => ScruterConsentState.unavailable,
      };

  /// The current valid choice; `null` before the first one and while the banner asks again.
  static ScruterChoice? get choice => _c.current;

  /// The visitor's receipt (`cns_…`), shown in the preferences; `null` before a first choice.
  static String? get consentId => _c.snapshot['consentId'] as String?;

  /// Called once a valid choice exists: now, or after the decision. Start the app's optional SDKs here.
  static ScruterSubscription whenReady(void Function(ScruterChoice choice) callback) {
    final c = _c;
    var live = true;
    void once(ScruterChoice choice) {
      if (live) callback(choice);
    }

    final now = c.current;
    if (now != null) {
      scheduleMicrotask(() => c.each([once], now));
    } else {
      c.ready.add(once);
    }
    return ScruterSubscription._(() {
      live = false;
      c.ready.remove(once);
    });
  }

  /// Called on every later change: the preferences, a withdrawal, the banner asking again.
  static ScruterSubscription onChange(void Function(ScruterChoice choice) callback) {
    final c = _c;
    void f(ScruterChoice choice) => callback(choice);
    c.changes.add(f);
    return ScruterSubscription._(() => c.changes.remove(f));
  }

  /// The current choice, then every new one: the first decision, the preferences, a withdrawal, a re-ask answered.
  static Stream<ScruterChoice> get choices async* {
    final c = _c;
    final now = c.current;
    if (now != null) yield now;
    yield* c.stream.stream;
  }

  /// The app's settings entry (« Privacy choices »): the preferences, where the visitor changes or withdraws.
  static Future<void> showPreferences() async {
    if (!_c.started) {
      _c.log('showPreferences before start: ignored');
      return;
    }
    await _c.call<void>('showPreferences');
  }

  /// With [ScruterPresentation.manual]: shows the sheet when a decision is needed. Returns whether it shows.
  static Future<bool> showIfNeeded() async {
    if (!_c.started) return false;
    return await _c.call<bool>('showIfNeeded') ?? false;
  }

  /// The Google Consent Mode signals of the current choice: every one denied until a choice exists but
  /// `security_storage`. Pass them to `FirebaseAnalytics.instance.setConsent`.
  static Map<String, ScruterConsentStatus> consentModeSignals() {
    final s = (_c.snapshot['signals'] as Map?) ?? const {};
    return {
      for (final k in scruterConsentSignals)
        k: k == 'security_storage' || s[k] == 'granted' ? ScruterConsentStatus.granted : ScruterConsentStatus.denied,
    };
  }

  /// Apple's tracking prompt after the CMP, only for a visitor who granted `advertising` (§3.9): otherwise the current
  /// status, without asking. Android has no such prompt: [ScruterTrackingStatus.unsupported].
  static Future<ScruterTrackingStatus> requestTrackingIfGranted() async {
    if (!_c.started) return ScruterTrackingStatus.notDetermined;
    final s = await _c.call<String>('requestTrackingIfGranted');
    return ScruterTrackingStatus.values.firstWhere((v) => v.name == s, orElse: () => ScruterTrackingStatus.notDetermined);
  }

  /// The banner's language (`'de'`), for an app with its own language setting; `null` follows the device again.
  static void setLanguage(String? language) {
    _c.language = language?.toLowerCase();
    if (_c.started) _c.call<void>('setLanguage', <String, Object?>{'language': _c.language});
  }

  /// Logs the state and every decision: the native module's to Xcode's console or Logcat, this layer's to the console.
  static bool get debug => _c.debug;
  static set debug(bool on) {
    _c.debug = on;
    if (_c.started) _c.call<void>('setDebug', <String, Object?>{'on': on});
  }

  /// Shows the sheet at every opening, even with a valid choice (screenshots, tests). Set it before [start].
  static bool get forceShow => _c.forceShow;
  static set forceShow(bool on) {
    _c.forceShow = on;
    if (_c.started) _c.call<void>('setForceShow', <String, Object?>{'on': on});
  }

  /// Forgets the choice in a debug build (a release build withdraws through the preferences): the sheet shows again.
  static Future<void> debugReset() async {
    if (_c.started) await _c.call<void>('debugReset');
  }
}
