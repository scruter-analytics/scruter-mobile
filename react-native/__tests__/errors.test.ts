import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { nativeModule } from '../__mocks__/react-native';
import { currentBundleId, describe as describeError, installErrorHandler, parseStack } from '../src/errors';

const HERMES = `TypeError: undefined is not a function
    at onPress (address at index.android.bundle:1:123456)
    at anonymous (address at /data/user/0/fr.ateliermona.app/files/index.android.bundle:1:777)
    at ?anon_0_ (address at index.android.bundle:1:9)
    at call (native)
    at apply (native)`;
const HERMES_DEV = `Error: x
    at onPress (http://10.0.2.2:8081/index.bundle?platform=android&dev=true:12345:27)
    at http://10.0.2.2:8081/index.bundle?platform=android:2:3`;
const JSC = `onPress@main.jsbundle:1:2345
@file:///var/containers/Bundle/Application/1F2E3D4C/App.app/main.jsbundle:1:77
map@[native code]
global code@main.jsbundle:1:10`;

describe('parseStack', () => {
  it('reads Hermes bytecode frames: line 1, the offset as column, the file only', () => {
    expect(parseStack(HERMES)).toEqual([
      { fn: 'onPress', fl: 'index.android.bundle', l: 1, co: 123456, ia: 1 },
      { fl: 'index.android.bundle', l: 1, co: 777, ia: 1 },
      { fn: '?anon_0_', fl: 'index.android.bundle', l: 1, co: 9, ia: 1 },
      { fn: 'call' },
      { fn: 'apply' },
    ]);
  });

  it('reads a development server\'s URLs without their query', () => {
    expect(parseStack(HERMES_DEV)).toEqual([
      { fn: 'onPress', fl: 'index.bundle', l: 12345, co: 27, ia: 1 },
      { fl: 'index.bundle', l: 2, co: 3, ia: 1 },
    ]);
  });

  it('reads JavaScriptCore frames and drops the container\'s path', () => {
    const frames = parseStack(JSC);
    expect(frames).toEqual([
      { fn: 'onPress', fl: 'main.jsbundle', l: 1, co: 2345, ia: 1 },
      { fl: 'main.jsbundle', l: 1, co: 77, ia: 1 },
      { fn: 'map' },
      { fn: 'global code', fl: 'main.jsbundle', l: 1, co: 10, ia: 1 },
    ]);
    expect(JSON.stringify(frames)).not.toContain('1F2E3D4C');
  });

  it('keeps 64 frames and never returns none', () => {
    const long = ['Error: x', ...Array.from({ length: 100 }, (_, i) => `    at f${i} (address at b:1:${i})`)].join('\n');
    expect(parseStack(long)).toHaveLength(64);
    expect(parseStack(undefined)).toEqual([{ fn: '?' }]);
    expect(parseStack('no frames here')).toEqual([{ fn: '?' }]);
  });
});

describe('describe', () => {
  it('takes the name and the message, cut to 200', () => {
    expect(describeError(new TypeError('x'.repeat(300)))).toEqual({ type: 'TypeError', reason: 'x'.repeat(200) });
  });

  it('survives anything thrown', () => {
    expect(describeError('boom')).toEqual({ type: 'Error', reason: 'boom' });
    expect(describeError(null)).toEqual({ type: 'Error', reason: '' });
    expect(describeError(42)).toEqual({ type: 'Error', reason: '' });
  });
});

describe('installErrorHandler', () => {
  function utils() {
    const u = {
      handler: undefined as undefined | ((e: unknown, f?: boolean) => void),
      getGlobalHandler: () => u.previous,
      setGlobalHandler: (h: (e: unknown, f?: boolean) => void) => {
        u.handler = h;
      },
      previous: jest.fn(),
    };
    return u;
  }
  const native = () => ({ ...nativeModule, reportError: jest.fn(() => true), defaultBundleId: () => 'rn-ios-1-1' });

  it('reports before the previous handler runs, which aborts a release build', () => {
    const u = utils();
    const n = native();
    const order: string[] = [];
    n.reportError.mockImplementation(() => {
      order.push('report');
      return true;
    });
    u.previous.mockImplementation(() => order.push('previous'));
    installErrorHandler(n as never, false, u);
    const e = new TypeError('oops');
    e.stack = HERMES;
    u.handler?.(e, true);
    expect(order).toEqual(['report', 'previous']);
    expect(u.previous).toHaveBeenCalledWith(e, true);
    const [fatal, type, reason, frames, id] = n.reportError.mock.calls[0] as unknown as [boolean, string, string, unknown[], string];
    expect([fatal, type, reason, id]).toEqual([true, 'TypeError', 'oops', 'rn-ios-1-1']);
    expect(frames).toHaveLength(5);
  });

  it('counts a non-fatal error as such, and a fatal one in __DEV__ too: it only shows the red screen', () => {
    const u = utils();
    const n = native();
    installErrorHandler(n as never, true, u);
    u.handler?.(new Error('dev'), true);
    expect((n.reportError.mock.calls[0] as unknown as unknown[])[0]).toBe(false);
    const v = utils();
    const m = native();
    installErrorHandler(m as never, false, v);
    v.handler?.(new Error('soft'), false);
    expect((m.reportError.mock.calls[0] as unknown as unknown[])[0]).toBe(false);
  });

  it('never stands between the app and its handler', () => {
    const u = utils();
    const n = native();
    n.reportError.mockImplementation(() => {
      throw new Error('native');
    });
    installErrorHandler(n as never, false, u);
    expect(() => u.handler?.(new Error('x'), true)).not.toThrow();
    expect(u.previous).toHaveBeenCalled();
  });

  it('does nothing without ErrorUtils', () => {
    expect(() => installErrorHandler(native() as never, false, undefined)).not.toThrow();
  });
});

describe('currentBundleId', () => {
  afterEach(() => {
    delete (globalThis as { __SCRUTER_DEBUG_ID__?: string }).__SCRUTER_DEBUG_ID__;
  });

  it('prefers the id of the bundle over the build\'s', () => {
    expect(currentBundleId(nativeModule as never)).toBe('rn-ios-2.3.0-230');
    (globalThis as { __SCRUTER_DEBUG_ID__?: string }).__SCRUTER_DEBUG_ID__ = 'abc';
    expect(currentBundleId(nativeModule as never)).toBe('abc');
  });
});

describe('conformance', () => {
  it('a JS crash report built from these frames validates against the protocol\'s schema', () => {
    const session = '9c1b2d3e4f5a6b7c';
    const batch = {
      v: 1,
      a: 'ATMONA02',
      b: '0f3c9a1e7b2d4c6a8e0f1a2b3c4d5e6f',
      t: 1762345678901,
      sdk: 'react_native/1.1.0',
      ce: '',
      dbg: 0,
      s: [
        {
          id: session,
          d: '4f2a9c1e7b3d5f6a8c0e2b4d6f8a0c2e',
          q: 1,
          st: 1762345000000,
          p: 'ios',
          bid: 'fr.ateliermona.app',
          av: '2.3.0',
          ab: '230',
          bk: 'release',
          tm: 0,
          os: '18.2',
          m: 'iPhone16,2',
          f: 'phone',
          l: 'fr',
          c: { sv: 1, ev: 0, dur: 3, en: 'Home', ex: 'Home', rev: {}, cr: 1, anr: 0, last: 1762345003000 },
        },
      ],
      cr: [HERMES, JSC, undefined].map((stack, i) => ({
        s: session,
        id: `a1b2c3d4e5f6071${i}`,
        t: 1762345214000,
        k: 'crash',
        src: 'js',
        ex: describeError(Object.assign(new TypeError('x'), {})),
        th: [{ c: 1, m: 1, f: parseStack(stack) }],
        bun: 'rn-ios-2.3.0-230',
      })),
    };
    const dir = mkdtempSync(join(tmpdir(), 'scruter-conformance-'));
    const file = join(dir, 'batch.json');
    writeFileSync(file, JSON.stringify(batch));
    expect(() =>
      execFileSync('node', [join(__dirname, '../../protocol/validate.mjs'), 'batch', file], { stdio: 'pipe' }),
    ).not.toThrow();
  });
});
