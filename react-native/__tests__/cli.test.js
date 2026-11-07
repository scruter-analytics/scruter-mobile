const { execFile, execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { parseArgs } = require('../cli/args');
const project = require('../cli/project');
const { debugIdOf, defaultBundleId, mappingId, prepare } = require('../cli/upload');

const CLI = path.join(__dirname, '../cli/index.js');
const VALIDATE = path.join(__dirname, 'helpers/validate.mjs');
const TOKEN = `scr_up_${'a'.repeat(43)}`;
const MAP = { version: 3, sources: ['App.tsx'], sourcesContent: ['const secret = 1;'], names: [], mappings: 'AAAA' };
const HERMES_MAP = { ...MAP, x_facebook_sources: [[null]], x_hermes_function_offsets: { 0: [0] } };

/** The API of docs/API.md §5.3, every body checked against the protocol's schema. */
function fakeApi({ have = [], status = {} } = {}) {
  const requests = [];
  const bad = [];
  const uploads = new Map();
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks);
      const send = (code, body) => {
        res.statusCode = code;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify(body ?? {}));
      };
      requests.push({ method: req.method, url: req.url, auth: req.headers.authorization });
      if (status[req.url]) return send(status[req.url]);
      if (req.method === 'PUT') {
        uploads.set(req.url, raw);
        return send(200);
      }
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return send(401);
      if (req.url === '/m/v1/symbols/missing') {
        const body = JSON.parse(raw);
        check('missing', body, bad);
        return send(200, { missing: body.files.filter((f) => !have.includes(f.debug_id)) });
      }
      if (req.url === '/m/v1/symbols') {
        const body = JSON.parse(raw);
        check('upload', body, bad);
        const id = `f${requests.length}`;
        requests[requests.length - 1].body = body;
        return send(201, {
          id,
          upload: {
            method: 'PUT',
            url: `http://127.0.0.1:${server.address().port}/put/${id}`,
            headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': String(body.size) },
            expires_at: '2026-11-06T12:00:00Z',
          },
        });
      }
      if (/^\/m\/v1\/symbols\/f\d+\/complete$/.test(req.url)) return send(202);
      send(404);
    });
  });
  return new Promise((resolve) =>
    server.listen(0, '127.0.0.1', () =>
      resolve({
        url: `http://127.0.0.1:${server.address().port}`,
        requests,
        uploads,
        bad,
        close: () => new Promise((r) => server.close(r)),
      }),
    ),
  );
}

function check(def, body, bad) {
  try {
    execFileSync('node', [VALIDATE, 'symbols', def], { input: JSON.stringify(body), stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (e) {
    bad.push(String(e.stderr));
  }
}

function run(args, env = {}) {
  return new Promise((resolve) => {
    execFile(
      'node',
      [CLI, ...args],
      { env: { PATH: process.env.PATH, SCRUTER_UPLOAD_TOKEN: TOKEN, ...env } },
      (error, stdout, stderr) => resolve({ code: error ? error.code : 0, stdout, stderr }),
    );
  });
}

/** An app as a release build leaves it. */
function app({ map = HERMES_MAP, androidMap = true, iosMap = true, mapping = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scruter-app-'));
  const write = (p, text) => {
    const f = path.join(root, p);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, text);
    return f;
  };
  write('android/app/build.gradle', 'defaultConfig {\n versionCode 230\n versionName "2.3.0"\n}\n');
  write('android/gradle.properties', 'hermesEnabled=true\n');
  write('ios/Atelier/Info.plist', '<key>CFBundleShortVersionString</key>\n<string>$(MARKETING_VERSION)</string>\n<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>');
  write('ios/Atelier.xcodeproj/project.pbxproj', 'CURRENT_PROJECT_VERSION = 231;\nMARKETING_VERSION = 2.3.1;\n');
  write('ios/Podfile.lock', '  - hermes-engine (0.81.0)\n');
  write('ios/Pods/Pods.xcodeproj/project.pbxproj', 'nothing about the app\n');
  if (androidMap) write('android/app/build/generated/sourcemaps/react/release/index.android.bundle.map', JSON.stringify(map));
  if (iosMap) write('main.jsbundle.map', JSON.stringify(map));
  if (mapping) write('android/app/build/outputs/mapping/release/mapping.txt', '# compiler: R8\n# pg_map_id: 3e0a8f2\ncom.a -> b:\n');
  return root;
}

describe('arguments', () => {
  it('needs the command and the app', () => {
    expect(parseArgs([]).error).toContain('symbols upload');
    expect(parseArgs(['symbols', 'upload']).error).toContain('--app');
    expect(parseArgs(['symbols', 'upload', '--app', 'nope']).error).toContain('not an app id');
    expect(parseArgs(['symbols', 'upload', '--app', 'A', '--nope']).error).toContain('unknown option');
    expect(parseArgs(['symbols', 'upload', '--app', 'A', '--sourcemap', 'x']).error).toContain('--platform');
  });

  it('reads the options', () => {
    const a = parseArgs(['symbols', 'upload', '--app', 'ATMONA02', '--platform', 'ios', '--dsym', 'a', '--dsym', 'b', '--strict']);
    expect(a).toMatchObject({ app: 'ATMONA02', platform: 'ios', dsym: ['a', 'b'], strict: true });
  });
});

describe('debug ids', () => {
  it('reads a map\'s own id, then the polyfill\'s file name', () => {
    expect(debugIdOf({ debugId: 'x' })).toBe('x');
    const id = '1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9';
    expect(debugIdOf({ sources: [`/tmp/scruter-metro-a/scruter-debug-id-ios-${id}.js`] })).toBe(id);
    expect(debugIdOf({ sources: ['App.tsx'] })).toBeUndefined();
  });

  it('makes the same default id as the native modules, within the schema', () => {
    expect(defaultBundleId('ios', '2.3.0', '230')).toBe('rn-ios-2.3.0-230');
    expect(defaultBundleId('android', '2.3 beta', '1+2')).toBe('rn-android-2.3_beta-1_2');
  });

  it('reads R8\'s id', () => {
    const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'scruter-')), 'mapping.txt');
    fs.writeFileSync(f, '# pg_map_id: abc123\n');
    expect(mappingId(f)).toBe('abc123');
    fs.writeFileSync(f, 'com.a -> b:\n# pg_map_id: late\n');
    expect(mappingId(f)).toBeUndefined();
  });

  it('sends the map with its id and without the app\'s source code', () => {
    const out = JSON.parse(zlib.gunzipSync(prepare(MAP, 'id-1')));
    expect(out.debugId).toBe('id-1');
    expect(out.sourcesContent).toBeUndefined();
    expect(out.mappings).toBe('AAAA');
  });
});

describe('the project', () => {
  it('reads versions from Gradle, from Xcode\'s settings and from Expo', () => {
    const root = app();
    expect(project.androidVersion(root)).toEqual({ version: '2.3.0', build: '230' });
    expect(project.iosVersion(root)).toEqual({ version: '2.3.1', build: '231' });
    const expo = fs.mkdtempSync(path.join(os.tmpdir(), 'scruter-expo-'));
    fs.writeFileSync(path.join(expo, 'app.json'), JSON.stringify({ expo: { version: '3.0.0', ios: { buildNumber: '7' }, android: { versionCode: 8 } } }));
    expect(project.iosVersion(expo)).toEqual({ version: '3.0.0', build: '7' });
    expect(project.androidVersion(expo)).toEqual({ version: '3.0.0', build: '8' });
  });

  it('never takes a debug variant\'s map', () => {
    const root = app({ androidMap: false });
    const f = path.join(root, 'android/app/build/generated/sourcemaps/react/debug/index.android.bundle.map');
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, '{}');
    expect(project.findSourceMap(root, 'android')).toBeUndefined();
  });
});

describe('scruter symbols upload', () => {
  it('uploads both source maps and the R8 mapping, each by the four steps of the contract', async () => {
    const api = await fakeApi();
    const root = app();
    const r = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', root, '--api', api.url]);
    await api.close();
    expect(r.code).toBe(0);
    expect(api.bad).toEqual([]);
    const declared = api.requests.filter((q) => q.url === '/m/v1/symbols').map((q) => q.body);
    expect(declared.map((d) => [d.platform, d.kind, d.debug_id, d.app_version, d.build])).toEqual([
      ['react_native', 'source_map', 'rn-android-2.3.0-230', '2.3.0', '230'],
      ['react_native', 'source_map', 'rn-ios-2.3.1-231', '2.3.1', '231'],
      ['android', 'r8_mapping', '3e0a8f2', '2.3.0', '230'],
    ]);
    expect(api.uploads.size).toBe(3);
    const [first] = [...api.uploads.values()];
    expect(crypto.createHash('sha256').update(first).digest('hex')).toBe(declared[0].sha256);
    const sent = JSON.parse(zlib.gunzipSync(first));
    expect(sent.debugId).toBe('rn-android-2.3.0-230');
    expect(sent.sourcesContent).toBeUndefined();
    expect(api.requests.filter((q) => q.url.endsWith('/complete'))).toHaveLength(3);
    // The token travels in the header only.
    expect(r.stdout + r.stderr).not.toContain(TOKEN);
  });

  it('skips what the server has', async () => {
    const api = await fakeApi({ have: ['rn-android-2.3.0-230', 'rn-ios-2.3.1-231', '3e0a8f2'] });
    const r = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', app(), '--api', api.url]);
    await api.close();
    expect(r.code).toBe(0);
    expect(api.uploads.size).toBe(0);
    expect(r.stdout).toContain('already on Scruter');
  });

  it('moves on when the server already has the file (409)', async () => {
    const api = await fakeApi({ status: { '/m/v1/symbols': 409 } });
    const r = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', app({ iosMap: false, mapping: false }), '--api', api.url]);
    await api.close();
    expect(r.code).toBe(0);
    expect(r.stdout).toContain('already on Scruter');
  });

  it('never fails a build unless --strict says so', async () => {
    const api = await fakeApi({ status: { '/m/v1/symbols/missing': 401 } });
    const root = app({ iosMap: false, mapping: false });
    const soft = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', root, '--api', api.url]);
    const strict = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', root, '--api', api.url, '--strict']);
    await api.close();
    expect(soft.code).toBe(0);
    expect(soft.stdout).toContain('token is unknown or revoked');
    expect(strict.code).toBe(1);
  });

  it('asks for a token, from the environment only', async () => {
    const r = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', app()], { SCRUTER_UPLOAD_TOKEN: '' });
    expect(r.code).toBe(0);
    expect(r.stdout).toContain('SCRUTER_UPLOAD_TOKEN is not set');
    const bad = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', app(), '--strict'], { SCRUTER_UPLOAD_TOKEN: 'nope' });
    expect(bad.code).toBe(1);
  });

  it('uses the id withScruter wrote, and --bundle-id over it', async () => {
    const id = '1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9';
    const map = { ...HERMES_MAP, sources: ['App.tsx', `/tmp/x/scruter-debug-id-ios-${id}.js`] };
    const api = await fakeApi();
    const root = app({ map, androidMap: false, mapping: false });
    await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', root, '--api', api.url, '--platform', 'ios', '--no-native']);
    await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', root, '--api', api.url, '--platform', 'ios', '--no-native', '--bundle-id', 'mine']);
    await api.close();
    expect(api.requests.filter((q) => q.url === '/m/v1/symbols').map((q) => q.body.debug_id)).toEqual([id, 'mine']);
  });

  it('warns about a Hermes build whose map is not composed, and accepts JavaScriptCore\'s', async () => {
    const api = await fakeApi();
    const hermes = await run(['symbols', 'upload', '--app', 'A', '--root', app({ map: MAP, iosMap: false, mapping: false }), '--api', api.url]);
    expect(hermes.stdout).toContain('not composed');
    const root = app({ map: MAP, iosMap: false, mapping: false });
    fs.writeFileSync(path.join(root, 'android/gradle.properties'), 'hermesEnabled=false\n');
    const jsc = await run(['symbols', 'upload', '--app', 'A', '--root', root, '--api', api.url]);
    await api.close();
    expect(jsc.stdout).not.toContain('not composed');
  });

  it('says how to get the iOS map when it is asked for and absent', async () => {
    const api = await fakeApi();
    const r = await run(['symbols', 'upload', '--app', 'A', '--root', app({ iosMap: false }), '--platform', 'ios', '--api', api.url, '--no-native']);
    await api.close();
    expect(r.stdout).toContain('SOURCEMAP_FILE');
  });

  it('sends nothing on a dry run, and needs no token for it', async () => {
    const r = await run(['symbols', 'upload', '--app', 'ATMONA02', '--root', app(), '--dry-run'], { SCRUTER_UPLOAD_TOKEN: '' });
    expect(r.code).toBe(0);
    expect(r.stdout).toContain('dry run');
    expect(r.stdout).toContain('r8_mapping 3e0a8f2');
  });

  it('prints its usage', async () => {
    const r = await run(['--help']);
    expect(r.stdout).toContain('--sourcemap');
    const bad = await run(['nope']);
    expect(bad.code).toBe(2);
  });
});
