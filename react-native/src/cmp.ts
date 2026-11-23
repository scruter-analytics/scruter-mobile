import { useEffect, useState } from 'react';
import { NativeEventEmitter } from 'react-native';
import native from './specs/NativeScruterCMP';
import { VERSION } from './scruter';

/** Where the CMP stands (docs/CMP-MOBILE.md §3.1). */
export type ScruterConsentState = 'ready' | 'needsDecision' | 'unavailable';

/** When the sheet shows: by itself once the app is on screen (`automatic`), or where the app calls `showIfNeeded()`. */
export type ScruterPresentation = 'automatic' | 'manual';

/** Apple's App Tracking Transparency status; `unsupported` on Android, which has no such prompt. */
export type ScruterTrackingStatus = 'notDetermined' | 'restricted' | 'denied' | 'authorized' | 'unsupported';

/** Google Consent Mode v2 signals (§3.7), named as Firebase names them. */
export type ScruterConsentSignal =
  | 'ad_storage'
  | 'ad_user_data'
  | 'ad_personalization'
  | 'analytics_storage'
  | 'functionality_storage'
  | 'personalization_storage'
  | 'security_storage';

export type ScruterConsentStatus = 'granted' | 'denied';

/** The purposes every Scruter banner may have; a banner adds its own keys (`isGranted('crash_reports')`). */
export const ScruterPurpose = {
  necessary: 'necessary',
  analytics: 'analytics',
  advertising: 'advertising',
  personalization: 'personalization',
  embeddedContent: 'embedded_content',
  socialMedia: 'social_media',
  functional: 'functional',
} as const;

/** A visitor's choice. */
export interface ScruterChoice {
  /** The receipt the visitor can give you to find their proofs (`cns_…`). */
  readonly consentId: string;
  readonly decidedAt: Date;
  /** The purposes granted, the required ones included. */
  readonly granted: readonly string[];
  /** The optional purposes refused. */
  readonly denied: readonly string[];
  isGranted(purpose: string): boolean;
}

export interface ScruterCMPStartOptions {
  /** The app's code in Scruter CMP (`ATMONA02`), on its page under Installation. */
  appId: string;
  /** `automatic` (default) or `manual` with `showIfNeeded()`. */
  presentation?: ScruterPresentation;
  /** Where the configuration is served (default `https://cdn.scruter.net`), for tests. */
  endpoint?: string;
}

/** Stops a `whenReady` or `onChange` callback. */
export interface ScruterSubscription {
  remove(): void;
}

type WireChoice = { consentId: string; decidedAt: number; granted: string[]; denied: string[] };
type Snapshot = {
  state?: ScruterConsentState;
  consentId?: string | null;
  choice?: WireChoice | null;
  granted?: string[];
  signals?: Record<string, string>;
};
type Change = { snapshot: Snapshot; newChoice: boolean };

export const CHANGE_EVENT = 'ScruterCMPChange';
const SIGNALS: ScruterConsentSignal[] = [
  'ad_storage',
  'ad_user_data',
  'ad_personalization',
  'analytics_storage',
  'functionality_storage',
  'personalization_storage',
  'security_storage',
];

let started = false;
let debug = false;
let forceShow = false;
let language: string | null = null;
let current: ScruterChoice | null = null;
let hadChoice = false;
const ready = new Set<(c: ScruterChoice) => void>();
const changes = new Set<(c: ScruterChoice) => void>();
/** `useConsentChoice`: every change of the current choice, its disappearance included. */
const watchers = new Set<(c: ScruterChoice | null) => void>();

function log(message: string) {
  if (debug) console.log(`[ScruterCMP] ${message}`);
}

function choiceOf(w: WireChoice | null | undefined): ScruterChoice | null {
  if (!w || typeof w.consentId !== 'string') return null;
  const granted = Object.freeze([...(w.granted ?? [])]);
  return Object.freeze({
    consentId: w.consentId,
    decidedAt: new Date(Number(w.decidedAt)),
    granted,
    denied: Object.freeze([...(w.denied ?? [])]),
    isGranted: (purpose: string) => purpose === 'necessary' || granted.includes(purpose),
  });
}

const keyOf = (c: ScruterChoice | null) => (c ? `${c.consentId}|${c.decidedAt.getTime()}|${c.granted.join(',')}` : '');

function read(): Snapshot {
  if (!started || !native) return {};
  try {
    return (native.snapshot() as Snapshot) ?? {};
  } catch {
    return {};
  }
}

function call<T>(set: Set<(v: T) => void>, value: T) {
  for (const f of [...set]) {
    try {
      f(value);
    } catch (e) {
      console.error('[ScruterCMP] a callback of the app threw', e);
    }
  }
}

/** A new snapshot: the ready queue once a choice exists, the change callbacks for every later one. */
function received({ snapshot, newChoice }: Change) {
  const next = choiceOf(snapshot.choice);
  const before = current;
  const changed = keyOf(next) !== keyOf(before);
  current = next;
  if (changed) call(watchers, next);
  if (!next) return;
  if (newChoice && changed) log(`choice ${next.consentId}: ${next.granted.join(', ')}`);
  if (ready.size) {
    const callbacks = new Set(ready);
    ready.clear();
    call(callbacks, next);
  }
  if (newChoice && changed && hadChoice) call(changes, next);
  hadChoice = true;
}

/**
 * Scruter CMP for React Native (docs/CMP-MOBILE.md §3.4): the native consent sheet of iOS and Android, the choice kept
 * in the app's own storage, its proofs and their queue, all in the native modules. Start it once, before
 * `AppRegistry`, then gate the app's SDKs:
 *
 * ```ts
 * ScruterCMP.start({ appId: 'ATMONA02' });
 * ScruterCMP.whenReady(applyConsent);
 * ScruterCMP.onChange(applyConsent);
 * ```
 *
 * Until a choice exists, every optional purpose is denied. Before `start`, every call is a no-op that grants nothing.
 */
export const ScruterCMP = {
  /** Starts the CMP once; a JavaScript reload starts nothing again (the native module runs once per process). */
  start(options: ScruterCMPStartOptions): void {
    if (started) {
      log('start called twice: ignored');
      return;
    }
    if (!native) {
      console.warn(
        '[ScruterCMP] the native module is not linked: add "scruter": { "cmp": true } to your app\'s package.json, then run pod install and rebuild. Expo Go cannot load it: use a development build.',
      );
      return;
    }
    started = true;
    new NativeEventEmitter(native as never).addListener(CHANGE_EVENT, (e: Change) => received(e));
    native.start({
      appId: options.appId,
      manual: options.presentation === 'manual',
      endpoint: options.endpoint ?? null,
      version: VERSION,
      forceShow,
      debug,
      language,
    });
    received({ snapshot: read(), newChoice: false });
    log(`started: ${ScruterCMP.state}`);
  },

  /** Whether `purpose` is granted now: synchronous, `false` for every optional purpose until a choice exists. */
  isGranted(purpose: string): boolean {
    return (read().granted ?? []).includes(purpose);
  },

  /** `ready`, `needsDecision` or `unavailable` (no configuration yet: every optional purpose denied). */
  get state(): ScruterConsentState {
    return read().state ?? 'unavailable';
  },

  /** The current valid choice; `null` before the first one and while the banner asks again. */
  get choice(): ScruterChoice | null {
    return started ? choiceOf(read().choice) : null;
  },

  /** The visitor's receipt (`cns_…`), shown in the preferences; `null` before a first choice. */
  get consentId(): string | null {
    return read().consentId ?? null;
  },

  /** Called once a valid choice exists: now, or after the decision. Start the app's optional SDKs here. */
  whenReady(callback: (choice: ScruterChoice) => void): ScruterSubscription {
    let live = true;
    const once = (c: ScruterChoice) => {
      if (live) callback(c);
    };
    if (current) {
      const now = current;
      Promise.resolve().then(() => call(new Set([once]), now));
    } else {
      ready.add(once);
    }
    return {
      remove() {
        live = false;
        ready.delete(once);
      },
    };
  },

  /** Called on every later change: the preferences, a withdrawal, the banner asking again. */
  onChange(callback: (choice: ScruterChoice) => void): ScruterSubscription {
    const f = (c: ScruterChoice) => callback(c);
    changes.add(f);
    return {
      remove() {
        changes.delete(f);
      },
    };
  },

  /** The app's settings entry (« Privacy choices »): the preferences, where the visitor changes or withdraws. */
  showPreferences(): void {
    if (!started || !native) return log('showPreferences before start: ignored');
    native.showPreferences();
  },

  /** With `presentation: 'manual'`: shows the sheet when a decision is needed. Returns whether it shows. */
  showIfNeeded(): boolean {
    if (!started || !native) return false;
    return native.showIfNeeded();
  },

  /** The Google Consent Mode signals of the current choice: every one denied until a choice exists but `security_storage`. */
  consentModeSignals(): Record<ScruterConsentSignal, ScruterConsentStatus> {
    const s = read().signals ?? {};
    const out = {} as Record<ScruterConsentSignal, ScruterConsentStatus>;
    for (const k of SIGNALS) out[k] = k === 'security_storage' || s[k] === 'granted' ? 'granted' : 'denied';
    return out;
  },

  /**
   * Apple's tracking prompt after the CMP, only for a visitor who granted `advertising` (§3.9): otherwise the current
   * status, without asking. Android has no such prompt: `unsupported`.
   */
  async requestTrackingIfGranted(): Promise<ScruterTrackingStatus> {
    if (!started || !native) return 'notDetermined';
    return (await native.requestTrackingIfGranted()) as ScruterTrackingStatus;
  },

  /** The banner's language (`'de'`), for an app with its own language setting; `null` follows the device again. */
  setLanguage(lang: string | null): void {
    language = lang ? lang.toLowerCase() : null;
    if (started) native?.setLanguage(language);
  },

  /** Logs the state and every decision: the native module's to Xcode's console or Logcat, this layer's to Metro. */
  get debug(): boolean {
    return debug;
  },
  set debug(on: boolean) {
    debug = on;
    if (started) native?.setDebug(on);
  },

  /** Shows the sheet at every opening, even with a valid choice (screenshots, tests). Set it before `start`. */
  get forceShow(): boolean {
    return forceShow;
  },
  set forceShow(on: boolean) {
    forceShow = on;
    if (started) native?.setForceShow(on);
  },

  /** Forgets the choice in a debug build (a release build withdraws through the preferences): the sheet shows again. */
  debugReset(): void {
    if (started) native?.debugReset();
  },
};

/** The current choice as React state: re-renders on every change, `null` before the first choice. */
export function useConsentChoice(): ScruterChoice | null {
  const [choice, setChoice] = useState<ScruterChoice | null>(current);
  useEffect(() => {
    const f = (c: ScruterChoice | null) => setChoice(c);
    watchers.add(f);
    setChoice(current);
    return () => {
      watchers.delete(f);
    };
  }, []);
  return choice;
}
