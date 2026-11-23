// What the SDK imports from React Native, recorded by the tests.
import * as React from 'react';

// One state across `jest.isolateModules`, which loads this file again.
const shared = ((globalThis as { __rn?: Record<string, unknown> }).__rn ??= {
  calls: [],
  urlListeners: [],
  initial: { url: null },
  moduleHolder: { value: undefined },
}) as {
  calls: Array<[string, ...unknown[]]>;
  urlListeners: Array<(e: { url: string }) => void>;
  initial: { url: string | null };
  moduleHolder: { value: unknown };
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

export const TurboModuleRegistry = {
  get: () => moduleHolder.value,
};

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
  addListener() {
    return { remove() {} };
  }
}

export const View = React.forwardRef<unknown, Record<string, unknown>>((props, ref) =>
  React.createElement('View', { ...props, ref } as never),
);
