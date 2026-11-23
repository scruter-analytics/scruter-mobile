import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * The native module of Scruter CMP, for both architectures, over the iOS module `ScruterCMP` and the Android module
 * `net.scruter:scruter-cmp`. Linked only when the app's package.json asks for it (`"scruter": { "cmp": true }`).
 * Methods that return a value run synchronously on the JS thread.
 */
export interface Spec extends TurboModule {
  /**
   * `appId`, `manual`, `endpoint`, `version`, `forceShow`, `debug`, `language`. Synchronous, so that the next line reads
   * the stored choice; `false` when the native module was started already (a JavaScript reload).
   */
  start(options: Object): boolean;
  /** `state`, `consentId`, `choice`, `granted`, `signals` (docs/CMP-MOBILE.md §3.16). */
  snapshot(): Object;
  showPreferences(): void;
  showIfNeeded(): boolean;
  requestTrackingIfGranted(): Promise<string>;
  setLanguage(language: string | null): void;
  setDebug(on: boolean): void;
  setForceShow(on: boolean): void;
  debugReset(): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

// `get`, not `getEnforcing`: without the native module (not linked, Expo Go), every call is a no-op and `start` says why.
export default TurboModuleRegistry.get<Spec>('ScruterCMP');
