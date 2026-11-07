import { Linking, NativeEventEmitter, Platform } from 'react-native';
import { installErrorHandler } from './errors';
import { track as trackRoutes } from './navigation';
import type { NavigationContainer, NavigationRefLike, ScreenNamer } from './navigation';
import native from './specs/NativeScruter';

/** The SDK's version, as batches name it (`react_native/1.0.0`). */
export const VERSION = '1.0.2';

export interface ScruterStartOptions {
  /** "App identifier" (`ATMONA02`), from App settings › SDK. */
  appId: string;
  /** The debug-build key (`scr_dbg_…`): a debug build becomes a team phone. Used only under `__DEV__`. */
  debugKey?: string;
  /** Logs every screen, event and batch to the console, Metro included. */
  debug?: boolean;
  /** Marks a build given to testers when the platform cannot tell. */
  testBuild?: boolean;
  /** The collection host (default `https://cdn.scruter.net`), for tests. */
  endpoint?: string;
  /** The API host (default `https://api.scruter.net`), for tests. */
  apiEndpoint?: string;
}

export interface ScruterTrackOptions {
  /** ≤ 30 properties: strings, numbers, booleans. Never personal data. */
  props?: Record<string, string | number | boolean | null | undefined>;
  /** In major units; counts only with its ISO 4217 `currency`. */
  revenue?: number;
  currency?: string;
}

export type ScruterFieldErrorKind = 'required' | 'format' | 'refused' | 'invalid';

let started = false;
let debug = false;
let lastRoute: { name: string; forward: boolean } | undefined;

const isDev = () => typeof __DEV__ !== 'undefined' && __DEV__;

function log(message: string) {
  if (debug) console.log(`[Scruter] ${message}`);
}

function route(name: string, forward: boolean) {
  lastRoute = { name, forward };
  if (started) native?.screen(name, forward);
}

let stopTracking: (() => void) | undefined;

/** Options of `Scruter.trackNavigation`. */
export interface ScruterNavigationOptions {
  /**
   * A clear name for a route: a string replaces it, `null` leaves it uncounted, `undefined` keeps the automatic one. It
   * receives the automatic name, then the whole route (`(tabs)/index`, `admin/job/[id]`).
   */
  screenName?: ScreenNamer;
}

/** A callback ref, usable as `<NavigationContainer ref={Scruter.navigationRef}>`; `.current` holds the container. */
interface NavigationRefCallback {
  (container: NavigationContainer | null): void;
  current: NavigationContainer | null;
}

const navigationRef: NavigationRefCallback = Object.assign(
  (container: NavigationContainer | null) => {
    navigationRef.current = container;
    stopTracking?.();
    stopTracking = container ? trackRoutes(container, route) : undefined;
  },
  { current: null as NavigationContainer | null },
);

/** How long a link counts as the same one: longer than the start of the bundle, shorter than a person scanning again. */
const SAME_LINK_MS = 5000;
let lastLink = { url: '', at: 0 };

/** iOS can hand the link that opens the app to `getInitialURL` and to the `url` event: one link, one call. */
function forward(url: string) {
  const at = Date.now();
  if (url === lastLink.url && at - lastLink.at < SAME_LINK_MS) return;
  lastLink = { url, at };
  native?.handle(url);
}

function listen() {
  Linking.addEventListener('url', ({ url }) => forward(url));
  // Android reads the launching intent itself. On iOS it depends on the app's lifecycle: launch options, or a scene's
  // connection options, which only React Native sees, and they went by before the SDK.
  if (Platform.OS === 'ios') {
    Linking.getInitialURL()
      .then((url) => {
        if (url) forward(url);
      })
      .catch(() => {});
  }
}

/**
 * Scruter Analytics for React Native (docs/MOBILE.md §3). Nothing but this object talks to the native SDKs, which do
 * the work: sessions, the daily identifier, the queue, taps, scroll, forms, native crashes, team phones.
 */
export const Scruter = {
  /** Starts Scruter once, before `AppRegistry`. Returns at once. Before it, every call is a no-op. */
  start(options: ScruterStartOptions): void {
    if (started) {
      log('start called twice: ignored');
      return;
    }
    if (!native) {
      console.warn(
        '[Scruter] the native module is not linked: nothing is collected. Expo Go cannot load it: use a development build; else run pod install and rebuild.',
      );
      return;
    }
    started = true;
    debug = options.debug === true;
    if (debug) {
      new NativeEventEmitter(native as never).addListener('ScruterLog', (line: string) =>
        console.log(`[Scruter] ${line}`),
      );
    }
    native.start({
      appId: options.appId,
      debugKey: isDev() ? (options.debugKey ?? null) : null,
      debug,
      testBuild: options.testBuild === true,
      endpoint: options.endpoint ?? null,
      apiEndpoint: options.apiEndpoint ?? null,
      version: VERSION,
    });
    installErrorHandler(native, isDev(), (globalThis as { ErrorUtils?: never }).ErrorUtils);
    // After the bundle's first turn: creating `Linking` waits for the main thread, busy with the launch.
    setTimeout(listen, 0);
    if (lastRoute) native.screen(lastRoute.name, lastRoute.forward);
  },

  /** `<NavigationContainer ref={Scruter.navigationRef}>`: each route counts as a screen, by its `name`. */
  navigationRef,

  /** The same for a ref of your own, or Expo Router's `useNavigationContainerRef()`. Returns what stops it. */
  trackNavigation(ref: NavigationRefLike, options: ScruterNavigationOptions = {}): () => void {
    return trackRoutes(ref, route, options.screenName);
  },

  /** Counts a screen view, for what navigation does not show. */
  screen(name: string): void {
    if (started) native?.screen(name, false);
  },

  /** Sends a custom event: `Scruter.track('Add to cart', { props: { color: 'blue' } })`. */
  track(name: string, options: ScruterTrackOptions = {}): void {
    if (!started) return;
    const props: Record<string, string> = {};
    for (const [key, value] of Object.entries(options.props ?? {})) {
      if (typeof value === 'string') props[key] = value;
      else if (typeof value === 'number' || typeof value === 'boolean') props[key] = String(value);
      else if (value !== null && value !== undefined) log(`track "${name}": property "${key}" dropped`);
    }
    native?.track(name, { props, revenue: options.revenue, currency: options.currency });
  },

  /** Reports an error shown on a form field (its `testID`, or its content type). */
  fieldError(key: string, kind: ScruterFieldErrorKind): void {
    if (started) native?.fieldError(key, kind);
  },

  /** Marks a form as sent (its `scruterForm`, else the screen's name). */
  formSent(name: string): void {
    if (started) native?.formSent(name);
  },

  /** The user objects to audience measurement: wire your "Audience measurement" setting to it. Kept across launches. */
  optOut(): void {
    if (started) native?.optOut();
  },

  /** Measured again, as a new install without an install day. */
  optIn(): void {
    if (started) native?.optIn();
  },

  get isOptedOut(): boolean {
    return started && native ? native.isOptedOut() : false;
  },

  /** Excludes this phone from the statistics (the team's own test phones). */
  ignoreThisDevice(): void {
    if (started) native?.ignoreThisDevice();
  },

  stopIgnoringThisDevice(): void {
    if (started) native?.stopIgnoringThisDevice();
  },

  get isDeviceIgnored(): boolean {
    return started && native ? native.isDeviceIgnored() : false;
  },

  /** Forwards a URL your app received outside `Linking` (`Linking` is followed by itself). */
  handle(url: string): void {
    if (started) native?.handle(url);
  },

  /** The app was opened from a notification, when the SDK cannot see it. */
  openedFromNotification(): void {
    if (started) native?.openedFromNotification();
  },

  /** Whether this phone is one of the team's phones (it takes the screen images of Screen analysis). */
  get isTeamPhone(): boolean {
    return started && native ? native.isTeamPhone() : false;
  },

  leaveTeamMode(): void {
    if (started) native?.leaveTeamMode();
  },

  /** Sends what waits now (the SDK sends on its own). */
  flush(): void {
    if (started) native?.flush();
  },
};
