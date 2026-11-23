const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { withScruter } = require('../metro');

const project = () => fs.mkdtempSync(path.join(os.tmpdir(), 'scruter-project-'));

describe('withScruter', () => {
  it('adds one polyfill per platform after the existing ones and keeps the rest of the config', () => {
    const config = withScruter({ projectRoot: project(), resetCache: true, serializer: { getPolyfills: () => ['base.js'], other: 1 } });
    expect(config.resetCache).toBe(true);
    expect(config.serializer.other).toBe(1);
    const ios = config.serializer.getPolyfills({ platform: 'ios' });
    const android = config.serializer.getPolyfills({ platform: 'android' });
    expect(ios[0]).toBe('base.js');
    expect(ios[1]).toMatch(/scruter-debug-id-ios-[0-9a-f-]{36}\.js$/);
    expect(android[1]).toMatch(/scruter-debug-id-android-/);
    expect(config.serializer.getPolyfills({ platform: 'ios' })[1]).toBe(ios[1]);
    const id = /([0-9a-f-]{36})\.js$/.exec(ios[1])[1];
    expect(fs.readFileSync(ios[1], 'utf8')).toBe(`global.__SCRUTER_DEBUG_ID__ = "${id}";\n`);
  });

  it('works without a serializer section', () => {
    expect(withScruter({ projectRoot: project() }).serializer.getPolyfills({ platform: 'ios' })).toHaveLength(1);
  });

  it('writes inside the project, before Metro looks at it, and leaves other platforms alone', () => {
    const root = project();
    const config = withScruter({ projectRoot: root });
    const files = fs.readdirSync(path.join(root, 'node_modules/.scruter'));
    expect(files).toHaveLength(2);
    expect(config.serializer.getPolyfills({ platform: 'web' })).toEqual([]);
  });

  it('removes the files of old builds', () => {
    const root = project();
    withScruter({ projectRoot: root });
    const dir = path.join(root, 'node_modules/.scruter');
    const old = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000);
    for (const f of fs.readdirSync(dir)) fs.utimesSync(path.join(dir, f), old, old);
    withScruter({ projectRoot: root });
    expect(fs.readdirSync(dir)).toHaveLength(2);
  });
});
