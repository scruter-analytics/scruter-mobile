/// Scruter Analytics for Flutter: screens, events, sessions, retention, crashes and Screen analysis, without an
/// advertising id, a device identifier, an ATT prompt or a consent banner. Guide: `README.md`.
///
/// Scruter CMP for Flutter: the consent sheet of Scruter CMP, native on iOS and Android, with the proof of every choice.
/// Guide: `CMP.md`.
library;

export 'src/cmp.dart'
    show
        ScruterChoice,
        ScruterCMP,
        ScruterConsentState,
        ScruterConsentStatus,
        ScruterPresentation,
        ScruterPurpose,
        ScruterSubscription,
        ScruterTrackingStatus,
        scruterConsentSignals;
export 'src/observer.dart' show ScruterObserver;
export 'src/scruter.dart' show Scruter, ScruterFieldError, scruterVersion;
export 'src/widgets.dart' show ScruterForm, ScruterId, ScruterIgnore, ScruterMask;
