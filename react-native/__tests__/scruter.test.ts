import { calls, initial, moduleHolder, nativeModule, urlListeners } from '../__mocks__/react-native';

type Sdk = typeof import('../src');

/** A fresh SDK for each test: `start` happens once per process. */
function load(): Sdk {
  let sdk!: Sdk;
  jest.isolateModules(() => {
    sdk = require('../src');
  });
  return sdk;
}

const named = (name: string) => calls.filter((c) => c[0] === name);

beforeEach(async () => {
  // What the previous test's `start` deferred.
  await new Promise((r) => setTimeout(r, 2));
  calls.length = 0;
  urlListeners.length = 0;
  initial.url = null;
  moduleHolder.value = nativeModule;
  (globalThis as { __DEV__?: boolean }).__DEV__ = false;
});

describe('start', () => {
  it('forwards the options, and keeps the debug key out of a release build', () => {
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02', debugKey: 'scr_dbg_x', testBuild: true });
    expect(named('start')[0]?.[1]).toEqual({
      appId: 'ATMONA02',
      debugKey: null,
      debug: false,
      testBuild: true,
      endpoint: null,
      apiEndpoint: null,
      version: '1.0.2',
    });
  });

  it('forwards the debug key under __DEV__', () => {
    (globalThis as { __DEV__?: boolean }).__DEV__ = true;
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02', debugKey: 'scr_dbg_x' });
    expect((named('start')[0]?.[1] as { debugKey: string }).debugKey).toBe('scr_dbg_x');
  });

  it('runs once, and every call before it is a no-op', () => {
    const { Scruter } = load();
    Scruter.track('Before');
    Scruter.screen('Before');
    Scruter.optOut();
    expect(Scruter.isOptedOut).toBe(false);
    Scruter.start({ appId: 'ATMONA02' });
    Scruter.start({ appId: 'ATMONA03' });
    expect(named('start')).toHaveLength(1);
    expect(named('track')).toHaveLength(0);
    expect(named('screen')).toHaveLength(0);
    expect(named('optOut')).toHaveLength(0);
  });

  it('says plainly when the native module is missing (Expo Go) and never throws', () => {
    moduleHolder.value = null;
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    Scruter.track('Nothing');
    expect(warn.mock.calls[0]?.[0]).toContain('Expo Go');
    warn.mockRestore();
  });
});

describe('events', () => {
  it('sends strings: numbers and booleans become text, the rest is dropped', () => {
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    Scruter.track('Add to cart', {
      props: { color: 'blue', size: 42, stock: true, empty: null, object: {} as never },
      revenue: 49,
      currency: 'EUR',
    });
    expect(named('track')[0]).toEqual([
      'track',
      'Add to cart',
      { props: { color: 'blue', size: '42', stock: 'true' }, revenue: 49, currency: 'EUR' },
    ]);
  });

  it('sends no revenue when there is none', () => {
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    Scruter.track('Vu');
    expect(named('track')[0]).toEqual(['track', 'Vu', { props: {} }]);
  });
});

describe('the rest of the API', () => {
  it('reaches the native module', () => {
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    Scruter.screen('Cart');
    Scruter.fieldError('postalCode', 'format');
    Scruter.formSent('Delivery');
    Scruter.optOut();
    Scruter.optIn();
    Scruter.ignoreThisDevice();
    Scruter.stopIgnoringThisDevice();
    Scruter.handle('https://atelier-mona.fr/shop');
    Scruter.openedFromNotification();
    Scruter.leaveTeamMode();
    Scruter.flush();
    expect(Scruter.isOptedOut).toBe(true);
    expect(Scruter.isDeviceIgnored).toBe(false);
    expect(Scruter.isTeamPhone).toBe(false);
    for (const name of ['screen', 'fieldError', 'formSent', 'optOut', 'optIn', 'ignoreThisDevice', 'stopIgnoringThisDevice', 'handle', 'openedFromNotification', 'leaveTeamMode', 'flush']) {
      expect(named(name)).toHaveLength(1);
    }
    expect(named('screen')[0]).toEqual(['screen', 'Cart', false]);
  });
});

describe('links', () => {
  it('forwards the URLs React Native receives and iOS\'s launch URL, after the bundle\'s first turn', async () => {
    initial.url = 'scruter-atmona02://team?t=scr_qr_abc';
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    expect(urlListeners).toHaveLength(0);
    await new Promise((r) => setTimeout(r, 1));
    urlListeners[0]?.({ url: 'https://atelier-mona.fr/shop?utm_source=x' });
    expect(named('handle').map((c) => c[1])).toEqual([
      'scruter-atmona02://team?t=scr_qr_abc',
      'https://atelier-mona.fr/shop?utm_source=x',
    ]);
  });

  it('calls once for the link iOS gives twice at launch, whichever way comes first', async () => {
    const link = 'scruter-atmona02://team?t=scr_qr_abc';
    for (const order of ['event first', 'launch URL first']) {
      calls.length = 0;
      urlListeners.length = 0;
      initial.url = link;
      const { Scruter } = load();
      Scruter.start({ appId: 'ATMONA02' });
      await new Promise((r) => setTimeout(r, 0));
      if (order === 'event first') urlListeners[0]?.({ url: link });
      await new Promise((r) => setTimeout(r, 1));
      urlListeners[0]?.({ url: link });
      expect(named('handle').map((c) => c[1])).toEqual([link]);
    }
  });

  it('calls again when the same link comes back later: a person scanning a code again', async () => {
    const link = 'scruter-atmona02://team?t=scr_qr_abc';
    const { Scruter } = load();
    Scruter.start({ appId: 'ATMONA02' });
    await new Promise((r) => setTimeout(r, 1));
    const now = Date.now();
    const clock = jest.spyOn(Date, 'now');
    clock.mockReturnValue(now);
    urlListeners[0]?.({ url: link });
    clock.mockReturnValue(now + 6000);
    urlListeners[0]?.({ url: link });
    clock.mockRestore();
    expect(named('handle').map((c) => c[1])).toEqual([link, link]);
  });
});

describe('the version', () => {
  it('is the package\'s', () => {
    const { version } = require('../package.json');
    let sdk!: { VERSION: string };
    jest.isolateModules(() => {
      sdk = require('../src/scruter');
    });
    expect(sdk.VERSION).toBe(version);
  });
});
