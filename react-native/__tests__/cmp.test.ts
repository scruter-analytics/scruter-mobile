import type TestRendererType from 'react-test-renderer';
import { calls, cmpHolder, cmpModule, cmpSnapshot, emit, emitted } from '../__mocks__/react-native';

type Sdk = typeof import('../src');

/** A fresh JavaScript context, as after a reload: the native module keeps running. */
function load(): Sdk {
  let sdk!: Sdk;
  jest.isolateModules(() => {
    sdk = require('../src');
  });
  return sdk;
}

const named = (name: string) => calls.filter((c) => c[0] === name);
const flush = () => new Promise((r) => setTimeout(r, 0));

const CHOICE = { consentId: 'cns_0123456789abcdef0123', decidedAt: 1790000000000, granted: ['analytics', 'necessary'], denied: ['advertising'] };
const READY = {
  state: 'ready',
  consentId: CHOICE.consentId,
  choice: CHOICE,
  granted: ['analytics', 'necessary'],
  signals: { analytics_storage: 'granted', ad_storage: 'denied', security_storage: 'granted' },
};
const NEEDS = { state: 'needsDecision', granted: ['necessary'], signals: { security_storage: 'granted' } };

function change(snapshot: object, newChoice: boolean) {
  emit('ScruterCMPChange', { snapshot, newChoice });
}

beforeEach(() => {
  calls.length = 0;
  emitted.length = 0;
  cmpSnapshot.value = NEEDS;
  cmpHolder.value = cmpModule;
});

describe('ScruterCMP.start', () => {
  it('forwards the options once, names the wrapper and listens before starting', () => {
    const { ScruterCMP } = load();
    ScruterCMP.forceShow = true;
    ScruterCMP.setLanguage('DE');
    ScruterCMP.start({ appId: 'ATMONA02', presentation: 'manual', endpoint: 'http://127.0.0.1:8787' });
    ScruterCMP.start({ appId: 'ATMONA03' });
    expect(named('cmp.start')).toEqual([
      ['cmp.start', { appId: 'ATMONA02', manual: true, endpoint: 'http://127.0.0.1:8787', version: '1.2.0', forceShow: true, debug: false, language: 'de' }],
    ]);
    expect(emitted.map((e) => e.event)).toEqual(['ScruterCMPChange']);
    expect(named('cmp.setForceShow')).toHaveLength(0);
    expect(named('cmp.setLanguage')).toHaveLength(0);
  });

  it('defaults to the automatic presentation and the production endpoint', () => {
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02' });
    expect(named('cmp.start')[0]?.[1]).toMatchObject({ manual: false, endpoint: null, forceShow: false, debug: false, language: null });
  });

  it('warns and grants nothing when the native module is not linked', () => {
    cmpHolder.value = null;
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02' });
    expect(warn.mock.calls[0]?.[0]).toContain('"scruter": { "cmp": true }');
    expect(ScruterCMP.isGranted('analytics')).toBe(false);
    expect(ScruterCMP.state).toBe('unavailable');
    expect(ScruterCMP.showIfNeeded()).toBe(false);
    warn.mockRestore();
  });
});

describe('before start', () => {
  it('grants nothing and calls nothing native', async () => {
    const { ScruterCMP } = load();
    ScruterCMP.showPreferences();
    ScruterCMP.debugReset();
    expect(ScruterCMP.isGranted('analytics')).toBe(false);
    expect(ScruterCMP.isGranted('necessary')).toBe(false);
    expect(ScruterCMP.state).toBe('unavailable');
    expect(ScruterCMP.choice).toBeNull();
    expect(ScruterCMP.consentId).toBeNull();
    expect(ScruterCMP.consentModeSignals()).toEqual({
      ad_storage: 'denied',
      ad_user_data: 'denied',
      ad_personalization: 'denied',
      analytics_storage: 'denied',
      functionality_storage: 'denied',
      personalization_storage: 'denied',
      security_storage: 'granted',
    });
    expect(await ScruterCMP.requestTrackingIfGranted()).toBe('notDetermined');
    expect(calls.filter((c) => String(c[0]).startsWith('cmp.'))).toEqual([]);
  });
});

describe('the answers', () => {
  it('reads the native module synchronously', () => {
    cmpSnapshot.value = READY;
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02' });
    expect(ScruterCMP.isGranted('analytics')).toBe(true);
    expect(ScruterCMP.isGranted('advertising')).toBe(false);
    expect(ScruterCMP.isGranted('necessary')).toBe(true);
    expect(ScruterCMP.state).toBe('ready');
    expect(ScruterCMP.consentId).toBe(CHOICE.consentId);
    const c = ScruterCMP.choice!;
    expect(c.consentId).toBe(CHOICE.consentId);
    expect(c.decidedAt.getTime()).toBe(CHOICE.decidedAt);
    expect(c.granted).toEqual(['analytics', 'necessary']);
    expect(c.denied).toEqual(['advertising']);
    expect(c.isGranted('analytics')).toBe(true);
    expect(c.isGranted('advertising')).toBe(false);
    expect(c.isGranted('necessary')).toBe(true);
    expect(ScruterCMP.consentModeSignals().analytics_storage).toBe('granted');
    expect(ScruterCMP.consentModeSignals().ad_storage).toBe('denied');
    expect(ScruterCMP.consentModeSignals().ad_user_data).toBe('denied');
    // During a re-ask: no valid choice, the unchanged purposes keep their answer.
    cmpSnapshot.value = { ...NEEDS, consentId: CHOICE.consentId, granted: ['analytics', 'necessary'] };
    expect(ScruterCMP.choice).toBeNull();
    expect(ScruterCMP.isGranted('analytics')).toBe(true);
    expect(ScruterCMP.consentId).toBe(CHOICE.consentId);
  });

  it('forwards the settings entry, the manual presentation, ATT, the language, debug and the reset', async () => {
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02', presentation: 'manual' });
    ScruterCMP.showPreferences();
    expect(ScruterCMP.showIfNeeded()).toBe(true);
    expect(await ScruterCMP.requestTrackingIfGranted()).toBe('authorized');
    ScruterCMP.setLanguage('fr');
    ScruterCMP.setLanguage(null);
    ScruterCMP.debug = true;
    expect(ScruterCMP.debug).toBe(true);
    ScruterCMP.forceShow = true;
    ScruterCMP.debugReset();
    expect(named('cmp.showPreferences')).toHaveLength(1);
    expect(named('cmp.showIfNeeded')).toHaveLength(1);
    expect(named('cmp.requestTrackingIfGranted')).toHaveLength(1);
    expect(named('cmp.setLanguage')).toEqual([['cmp.setLanguage', 'fr'], ['cmp.setLanguage', null]]);
    expect(named('cmp.setDebug')).toEqual([['cmp.setDebug', true]]);
    expect(named('cmp.setForceShow')).toEqual([['cmp.setForceShow', true]]);
    expect(named('cmp.debugReset')).toHaveLength(1);
  });
});

describe('whenReady and onChange', () => {
  it('a first launch: whenReady at the decision, onChange for every later change only', async () => {
    const { ScruterCMP } = load();
    const ready: string[] = [];
    const changed: string[][] = [];
    ScruterCMP.whenReady((c) => ready.push(c.consentId));
    ScruterCMP.onChange((c) => changed.push([...c.granted]));
    ScruterCMP.start({ appId: 'ATMONA02' });
    await flush();
    expect(ready).toEqual([]);
    change(READY, true);
    expect(ready).toEqual([CHOICE.consentId]);
    expect(changed).toEqual([]);
    // The same choice told again (Android's whenReady and onChange): nothing.
    change(READY, true);
    expect(changed).toEqual([]);
    const later = { ...READY, choice: { ...CHOICE, decidedAt: CHOICE.decidedAt + 60000, granted: ['necessary'], denied: ['advertising', 'analytics'] } };
    change(later, true);
    expect(changed).toEqual([['necessary']]);
    // A later whenReady answers at once, asynchronously.
    let late = 0;
    ScruterCMP.whenReady(() => late++);
    expect(late).toBe(0);
    await flush();
    expect(late).toBe(1);
  });

  it('a returning visitor: whenReady at once, nothing for the stored choice told again', async () => {
    cmpSnapshot.value = READY;
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02' });
    const ready: string[] = [];
    let changes = 0;
    ScruterCMP.whenReady((c) => ready.push(c.consentId));
    ScruterCMP.onChange(() => changes++);
    await flush();
    expect(ready).toEqual([CHOICE.consentId]);
    change(READY, true);
    expect(changes).toBe(0);
  });

  it('a re-ask then its answer, and a reset then a new decision, are changes', () => {
    cmpSnapshot.value = READY;
    const { ScruterCMP } = load();
    ScruterCMP.start({ appId: 'ATMONA02' });
    let changes = 0;
    ScruterCMP.onChange(() => changes++);
    change({ ...NEEDS, consentId: CHOICE.consentId, granted: ['analytics', 'necessary'] }, false);
    expect(changes).toBe(0);
    change({ ...READY, choice: { ...CHOICE, decidedAt: CHOICE.decidedAt + 1000 } }, true);
    expect(changes).toBe(1);
    change(NEEDS, false);
    change({ ...READY, choice: { ...CHOICE, consentId: 'cns_ffffffffffffffffffff' } }, true);
    expect(changes).toBe(2);
  });

  it('removes a callback', async () => {
    const { ScruterCMP } = load();
    let ready = 0;
    let changes = 0;
    ScruterCMP.whenReady(() => ready++).remove();
    const sub = ScruterCMP.onChange(() => changes++);
    ScruterCMP.start({ appId: 'ATMONA02' });
    change(READY, true);
    sub.remove();
    change({ ...READY, choice: { ...CHOICE, decidedAt: 1 } }, true);
    await flush();
    expect(ready).toBe(0);
    expect(changes).toBe(0);
  });

  it('a callback that throws does not stop the others', () => {
    const { ScruterCMP } = load();
    const error = jest.spyOn(console, 'error').mockImplementation(() => {});
    let second = 0;
    ScruterCMP.whenReady(() => {
      throw new Error('app');
    });
    ScruterCMP.whenReady(() => second++);
    ScruterCMP.start({ appId: 'ATMONA02' });
    change(READY, true);
    expect(second).toBe(1);
    expect(error).toHaveBeenCalled();
    error.mockRestore();
  });

  it('a reload: one listener in the new context, the old one gone', () => {
    const first = load();
    first.ScruterCMP.start({ appId: 'ATMONA02' });
    // React Native drops the old context's listeners with it.
    emitted.length = 0;
    cmpSnapshot.value = READY;
    const second = load();
    let changes = 0;
    second.ScruterCMP.onChange(() => changes++);
    second.ScruterCMP.start({ appId: 'ATMONA02' });
    expect(named('cmp.start')).toHaveLength(2);
    expect(emitted).toHaveLength(1);
    change({ ...READY, choice: { ...CHOICE, decidedAt: 5 } }, true);
    expect(changes).toBe(1);
  });
});

describe('useConsentChoice', () => {
  it('re-renders with every change of the choice', () => {
    // The SDK, React and the renderer from one module registry: one React.
    let sdk!: Sdk;
    let React!: typeof import('react');
    let TestRenderer!: typeof TestRendererType;
    jest.isolateModules(() => {
      sdk = require('../src');
      React = require('react');
      TestRenderer = require('react-test-renderer');
    });
    const { ScruterCMP, useConsentChoice } = sdk;
    const { act } = TestRenderer;
    ScruterCMP.start({ appId: 'ATMONA02' });
    const seen: Array<string | null> = [];
    function Probe() {
      const c = useConsentChoice();
      seen.push(c ? c.granted.join(',') : null);
      return null;
    }
    let r!: TestRendererType.ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(React.createElement(Probe));
    });
    act(() => change(READY, true));
    act(() => change(NEEDS, false));
    expect(seen[0]).toBeNull();
    expect(seen).toContain('analytics,necessary');
    expect(seen[seen.length - 1]).toBeNull();
    act(() => r.unmount());
  });
});

describe('ScruterPurpose', () => {
  it('names the keys of the banner', () => {
    const { ScruterPurpose } = load();
    expect(ScruterPurpose.embeddedContent).toBe('embedded_content');
    expect(ScruterPurpose.socialMedia).toBe('social_media');
  });
});
