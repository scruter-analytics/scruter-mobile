import { ScruterCMP } from '@scruter/react-native';
import type { ScruterChoice, ScruterTrackingStatus } from '@scruter/react-native';

/**
 * Stand-ins for the third-party SDKs an app gates on the CMP's answer (CMP.md, « Gate your SDKs »): the same decisions as
 * Firebase Analytics, Google Mobile Ads and an attribution SDK, without linking them. The real calls are in comments.
 */
export type Partners = {
  analyticsStarted: boolean;
  personalisedAds: boolean;
  attributionStarted: boolean;
  analyticsStorage: string;
  tracking: ScruterTrackingStatus | 'not asked';
  /** How many times this JavaScript context heard each callback: a reload starts again at 0, never doubles them. */
  ready: number;
  changes: number;
};

let state: Partners = {
  analyticsStarted: false,
  personalisedAds: false,
  attributionStarted: false,
  analyticsStorage: 'denied',
  tracking: 'not asked',
  ready: 0,
  changes: 0,
};
const listeners = new Set<(p: Partners) => void>();

function set(change: Partial<Partners>) {
  state = { ...state, ...change };
  for (const l of listeners) l(state);
}

export function partners(): Partners {
  return state;
}

export function watchPartners(l: (p: Partners) => void): () => void {
  listeners.add(l);
  return () => listeners.delete(l);
}

function apply(choice: ScruterChoice) {
  const signals = ScruterCMP.consentModeSignals();
  set({
    // Firebase: analytics().setAnalyticsCollectionEnabled(...) and analytics().setConsent({ analytics_storage: ... }).
    analyticsStarted: choice.isGranted('analytics'),
    analyticsStorage: signals.analytics_storage,
    // Google Mobile Ads: requestNonPersonalizedAdsOnly unless advertising is granted.
    personalisedAds: choice.isGranted('advertising'),
    // AppsFlyer, Adjust: start only with advertising, stop on a withdrawal.
    attributionStarted: choice.isGranted('advertising'),
  });
}

/** Wired once, right after `ScruterCMP.start`. */
export function wirePartners() {
  ScruterCMP.whenReady(async (choice) => {
    set({ ready: state.ready + 1 });
    apply(choice);
    // Apple's prompt after the CMP, only when advertising is granted (CMP.md, ATT).
    set({ tracking: await ScruterCMP.requestTrackingIfGranted() });
  });
  ScruterCMP.onChange((choice) => {
    set({ changes: state.changes + 1 });
    apply(choice);
  });
}
