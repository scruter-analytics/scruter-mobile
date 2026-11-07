import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/** The native module, for both architectures. Methods that return a value run synchronously on the JS thread. */
export interface Spec extends TurboModule {
  start(options: Object): void;
  screen(name: string, forward: boolean): void;
  /** `event`: `props`, `revenue`, `currency`. An object: the old architecture cannot carry a null number on Android. */
  track(name: string, event: Object): void;
  fieldError(key: string, kind: string): void;
  formSent(name: string): void;
  optOut(): void;
  optIn(): void;
  isOptedOut(): boolean;
  ignoreThisDevice(): void;
  stopIgnoringThisDevice(): void;
  isDeviceIgnored(): boolean;
  handle(url: string): void;
  openedFromNotification(): void;
  isTeamPhone(): boolean;
  leaveTeamMode(): void;
  flush(): void;
  /** Synchronous: a fatal error is on disk before the runtime aborts. */
  reportError(fatal: boolean, type: string, reason: string, frames: Array<Object>, bundleId: string): boolean;
  /** The bundle's debug id when the Metro helper is not used: platform, app version and build. */
  defaultBundleId(): string;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

// `get`, not `getEnforcing`: without the native module (Expo Go), every call is a no-op and `start` says why.
export default TurboModuleRegistry.get<Spec>('Scruter');
