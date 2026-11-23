import 'package:flutter/material.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

/// Stand-ins for the third-party SDKs an app gates on the CMP's answer (CMP.md, « Gate your SDKs »): the same decisions
/// as Firebase Analytics, Google Mobile Ads and an attribution SDK, without linking them. The real calls are in comments.
class Partners extends ChangeNotifier {
  Partners._();

  static final shared = Partners._();

  bool analyticsStarted = false;
  bool personalisedAds = false;
  bool attributionStarted = false;
  String analyticsStorage = 'denied';
  String tracking = 'not asked';

  /// How many times this isolate heard each callback: a hot restart starts again at 0, never doubles them.
  int ready = 0;
  int changes = 0;

  /// Wired once, right after `ScruterCMP.start`.
  void wire() {
    ScruterCMP.whenReady((choice) async {
      ready++;
      apply(choice);
      // Apple's prompt after the CMP, only when advertising is granted (CMP.md, ATT).
      tracking = (await ScruterCMP.requestTrackingIfGranted()).name;
      notifyListeners();
    });
    ScruterCMP.onChange((choice) {
      changes++;
      apply(choice);
    });
  }

  void apply(ScruterChoice choice) {
    // Firebase: FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(...) and setConsent(analyticsStorageConsentGranted: ...).
    analyticsStarted = choice.isGranted(ScruterPurpose.analytics);
    analyticsStorage = ScruterCMP.consentModeSignals()['analytics_storage']!.name;
    // Google Mobile Ads: AdRequest(nonPersonalizedAds: true) unless advertising is granted.
    personalisedAds = choice.isGranted(ScruterPurpose.advertising);
    // AppsFlyer, Adjust: start only with advertising, stop on a withdrawal.
    attributionStarted = choice.isGranted(ScruterPurpose.advertising);
    notifyListeners();
  }
}

/// The CMP's screen of the example: the state, the receipt, the stand-ins gated on the answer, the settings entry.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Privacy')),
        body: StreamBuilder<ScruterChoice>(
          stream: ScruterCMP.choices,
          builder: (context, snapshot) => ListenableBuilder(
            listenable: Partners.shared,
            builder: (context, _) {
              final p = Partners.shared;
              final choice = ScruterCMP.choice;
              return ListView(children: [
                _section(context, 'Scruter CMP'),
                _row('State', ScruterCMP.state.name),
                _row('Receipt', choice?.consentId ?? '—'),
                _row('whenReady · onChange', '${p.ready} · ${p.changes}'),
                _section(context, 'Gated on the answer'),
                _row('Analytics SDK', p.analyticsStarted ? 'started' : 'off'),
                _row('Ads', p.personalisedAds ? 'personalised' : 'non-personalised'),
                _row('Attribution', p.attributionStarted ? 'started' : 'off'),
                _row('analytics_storage', p.analyticsStorage),
                _row('Tracking (ATT)', p.tracking),
                _section(context, 'Settings'),
                // The settings entry first (CMP.md): how a visitor changes or withdraws their choice.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: FilledButton(onPressed: ScruterCMP.showPreferences, child: const Text('Privacy choices')),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: OutlinedButton(onPressed: ScruterCMP.debugReset, child: const Text('Reset the choice (debug)')),
                ),
              ]);
            },
          ),
        ),
      );

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );

  // A row of two texts, not a ListTile, whose semantics would merge them: the device check reads each value.
  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [Expanded(child: Text(label)), Text(value)]),
      );
}
