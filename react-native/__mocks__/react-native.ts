// What the SDK imports from React Native, recorded by the tests.
import * as React from 'react';

// One state across `jest.isolateModules`, which loads this file again.
const shared = ((globalThis as { __rn?: Record<string, unknown> }).__rn ??= {
  calls: [],
  urlListeners: [],
  initial: { url: null },
  moduleHolder: { value: undefined },
  cmpHolder: { value: undefined },
  cmpSnapshot: { value: {} },
  emitted: [],
}) as {
  calls: Array<[string, ...unknown[]]>;
  urlListeners: Array<(e: { url: string }) => void>;
  initial: { url: string | null };
  moduleHolder: { value: unknown };
  cmpHolder: { value: unknown };
  cmpSnapshot: { value: unknown };
  emitted: Array<{ event: string; listener: (e: unknown) => void }>;
};

export const calls = shared.calls;

const record =
  (name: string, result?: unknown) =>
  (...args: unknown[]) => {
    calls.push([name, ...args]);
    return result;
  };

export const nativeModule = {
  start: record('start'),
  screen: record('screen'),
  track: record('track'),
  fieldError: record('fieldError'),
  formSent: record('formSent'),
  optOut: record('optOut'),
  optIn: record('optIn'),
  isOptedOut: record('isOptedOut', true),
  ignoreThisDevice: record('ignoreThisDevice'),
  stopIgnoringThisDevice: record('stopIgnoringThisDevice'),
  isDeviceIgnored: record('isDeviceIgnored', false),
  handle: record('handle'),
  openedFromNotification: record('openedFromNotification'),
  isTeamPhone: record('isTeamPhone', false),
  leaveTeamMode: record('leaveTeamMode'),
  flush: record('flush'),
  reportError: record('reportError', true),
  defaultBundleId: record('defaultBundleId', 'rn-ios-2.3.0-230'),
  addListener: record('addListener'),
  removeListeners: record('removeListeners'),
};

export const moduleHolder = shared.moduleHolder;
if (moduleHolder.value === undefined) moduleHolder.value = nativeModule;

/** Scruter CMP's native module: what `snapshot` answers is `cmpSnapshot.value`. */
export const cmpSnapshot = shared.cmpSnapshot;
export const cmpModule = {
  start: record('cmp.start'),
  snapshot: (...args: unknown[]) => {
    calls.push(['cmp.snapshot', ...args]);
    return cmpSnapshot.value;
  },
  showPreferences: record('cmp.showPreferences'),
  showIfNeeded: record('cmp.showIfNeeded', true),
  requestTrackingIfGranted: (...args: unknown[]) => {
    calls.push(['cmp.requestTrackingIfGranted', ...args]);
    return Promise.resolve('authorized');
  },
  setLanguage: record('cmp.setLanguage'),
  setDebug: record('cmp.setDebug'),
  setForceShow: record('cmp.setForceShow'),
  debugReset: record('cmp.debugReset'),
  addListener: record('cmp.addListener'),
  removeListeners: record('cmp.removeListeners'),
};
export const cmpHolder = shared.cmpHolder;
if (cmpHolder.value === undefined) cmpHolder.value = cmpModule;

export const TurboModuleRegistry = {
  get: (name: string) => (name === 'ScruterCMP' ? cmpHolder.value : moduleHolder.value),
};

/** The listeners added to `NativeEventEmitter`, for the tests to emit to. */
export const emitted = shared.emitted;
export function emit(event: string, body: unknown) {
  for (const l of emitted.filter((x) => x.event === event)) l.listener(body);
}

export const urlListeners = shared.urlListeners;
export const initial = shared.initial;

export const Linking = {
  addEventListener: (_: string, listener: (e: { url: string }) => void) => {
    urlListeners.push(listener);
    return { remove() {} };
  },
  getInitialURL: () => Promise.resolve(initial.url),
};

export const Platform = { OS: 'ios' };

export class NativeEventEmitter {
  addListener(event: string, listener: (e: unknown) => void) {
    const entry = { event, listener };
    emitted.push(entry);
    return {
      remove() {
        emitted.splice(emitted.indexOf(entry), 1);
      },
    };
  }
}

export const View = React.forwardRef<unknown, Record<string, unknown>>((props, ref) =>
  React.createElement('View', { ...props, ref } as never),
);
