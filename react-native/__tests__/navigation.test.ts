import { calls, moduleHolder, nativeModule } from '../__mocks__/react-native';
import { screenName, track } from '../src/navigation';

/** A React Navigation container with its state in the test's hands. */
function container(initial: object | undefined, ready = true) {
  const listeners: Record<string, Array<() => void>> = { state: [], ready: [] };
  const c = {
    state: initial,
    ready,
    addListener(event: 'state' | 'ready', cb: () => void) {
      listeners[event]?.push(cb);
      return () => {
        listeners[event] = (listeners[event] ?? []).filter((x) => x !== cb);
      };
    },
    getRootState() {
      return c.state as never;
    },
    isReady() {
      return c.ready;
    },
    emit(event: 'state' | 'ready') {
      for (const cb of listeners[event] ?? []) cb();
    },
    count: () => (listeners.state ?? []).length,
  };
  return c;
}

const stack = (index: number, ...names: string[]) => ({
  type: 'stack',
  index,
  routes: names.map((n) => ({ key: `${n}-k`, name: n })),
});

describe('track', () => {
  it('reports the focused route by its name, once, never its params', () => {
    const c = container(stack(0, 'Home'));
    const seen: unknown[] = [];
    track(c, (n, f) => seen.push([n, f]));
    c.emit('state');
    c.state = {
      ...stack(0, 'Home'),
      routes: [{ key: 'Home-k', name: 'Home', params: { email: 'a@b.fr' } }],
    };
    c.emit('state');
    expect(seen).toEqual([['Home', false]]);
    expect(JSON.stringify(seen)).not.toContain('a@b.fr');
  });

  it('waits for the container to be ready', () => {
    const c = container(undefined, false);
    const seen: string[] = [];
    track(c, (n) => seen.push(n));
    expect(seen).toEqual([]);
    c.ready = true;
    c.state = stack(0, 'Home');
    c.emit('ready');
    expect(seen).toEqual(['Home']);
  });

  it('tells a push from a back and a tab', () => {
    const c = container(stack(0, 'Cart'));
    const seen: unknown[] = [];
    track(c, (n, f) => seen.push([n, f]));
    c.state = stack(1, 'Cart', 'Payment');
    c.emit('state');
    c.state = stack(0, 'Cart');
    c.emit('state');
    c.state = { type: 'tab', index: 1, routes: [{ key: 'a', name: 'Cart' }, { key: 'b', name: 'Shop' }] };
    c.emit('state');
    expect(seen).toEqual([
      ['Cart', false],
      ['Payment', true],
      ['Cart', false],
      ['Shop', false],
    ]);
  });

  it('follows nested navigators to the screen', () => {
    const c = container({
      type: 'tab',
      index: 1,
      routes: [
        { key: 'h', name: 'HomeTab' },
        { key: 's', name: 'ShopTab', state: stack(1, 'List', 'Product') },
      ],
    });
    const seen: string[] = [];
    track(c, (n) => seen.push(n));
    expect(seen).toEqual(['Product']);
  });

  it('accepts a ref object, and stops', () => {
    const c = container(stack(0, 'Home'));
    const stop = track({ current: c }, () => {});
    expect(c.count()).toBe(1);
    stop();
    expect(c.count()).toBe(0);
    expect(() => track({ current: null }, () => {})()).not.toThrow();
  });
});

describe('screenName', () => {
  it('is the route name', () => {
    expect(screenName(['HomeTab', 'product/[id]'])).toBe('product/[id]');
  });

  it('gives an Expo Router index its folder, past the route groups', () => {
    expect(screenName(['__root', '(tabs)', 'shop', 'index'])).toBe('shop');
    expect(screenName(['__root', '(tabs)', 'index'])).toBe('index');
  });

  it('never names what only organises routes', () => {
    expect(screenName(['__root'])).toBeUndefined();
    expect(screenName(['__root', '(tabs)'])).toBeUndefined();
    expect(screenName([])).toBeUndefined();
  });
});

describe('an app naming its screens', () => {
  function nav(names: string[]) {
    let at = 0;
    const listeners: Array<() => void> = [];
    return {
      go(i: number) {
        at = i;
        listeners.forEach((l) => l());
      },
      container: {
        isReady: () => true,
        addListener: (_: string, l: () => void) => {
          listeners.push(l);
          return () => {};
        },
        getRootState: () => ({ index: 0, routes: [{ key: names[at], name: names[at] as string }] }),
      },
    };
  }

  it('replaces a name, leaves a route uncounted, keeps the others', () => {
    const n = nav(['index', 'admin', 'article/[slug]', 'saved']);
    const seen: string[] = [];
    const names: Record<string, string | null> = { index: 'Home', admin: null, 'article/[slug]': 'Article' };
    track(n.container as never, (name) => seen.push(name), (route) => names[route]);
    [1, 2, 3].forEach((i) => n.go(i));
    expect(seen).toEqual(['Home', 'Article', 'saved']);
  });

  it('gives the whole route, past the root, to tell two index screens apart', () => {
    const paths: string[] = [];
    const seen: string[] = [];
    let chain = ['__root', '(tabs)', 'index'];
    const state = (names: string[], parent = ''): unknown => {
      const [head, ...rest] = names;
      const key = `${parent}/${head}`;
      return { index: 0, routes: [{ key, name: head, state: rest.length ? state(rest, key) : undefined }] };
    };
    const listeners: Array<() => void> = [];
    const container = {
      isReady: () => true,
      addListener: (_: string, l: () => void) => {
        listeners.push(l);
        return () => {};
      },
      getRootState: () => state(chain),
    };
    track(container as never, (name) => seen.push(name), (_, path) => {
      paths.push(path);
      return path.startsWith('admin') ? null : path === '(tabs)/index' ? 'Home' : undefined;
    });
    chain = ['__root', 'index'];
    listeners.forEach((l) => l());
    chain = ['__root', 'admin', 'job/[id]'];
    listeners.forEach((l) => l());
    expect(paths).toEqual(['(tabs)/index', 'index', 'admin/job/[id]']);
    expect(seen).toEqual(['Home', 'index']);
  });

  it('keeps the automatic name when the app\'s function throws', () => {
    const n = nav(['saved']);
    const seen: string[] = [];
    track(n.container as never, (name) => seen.push(name), () => {
      throw new Error('no');
    });
    expect(seen).toEqual(['saved']);
  });
});

describe('Scruter.navigationRef', () => {
  beforeEach(() => {
    calls.length = 0;
    moduleHolder.value = nativeModule;
  });

  it('is a ref React can call; a route seen before start counts at start', () => {
    let Scruter!: typeof import('../src').Scruter;
    jest.isolateModules(() => {
      Scruter = require('../src').Scruter;
    });
    const c = container(stack(0, 'Home'));
    Scruter.navigationRef(c);
    expect(Scruter.navigationRef.current).toBe(c);
    expect(calls.filter((x) => x[0] === 'screen')).toHaveLength(0);
    Scruter.start({ appId: 'ATMONA02' });
    expect(calls.filter((x) => x[0] === 'screen')).toEqual([['screen', 'Home', false]]);
    c.state = stack(1, 'Home', 'Product');
    c.emit('state');
    expect(calls.filter((x) => x[0] === 'screen')[1]).toEqual(['screen', 'Product', true]);
    Scruter.navigationRef(null);
    expect(Scruter.navigationRef.current).toBeNull();
    expect(c.count()).toBe(0);
  });
});
