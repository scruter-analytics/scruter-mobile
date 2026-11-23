#!/usr/bin/env node
// The release build of the example on a real runtime (an emulator or a simulator in the CI), against a local server that
// answers like the ingest and the API and checks every body with the protocol kit. Maestro does the touching.
//   node scripts/device-check.mjs android|ios <app file> [--arch new|old] [--helper]
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { validate } from '../../protocol/validate.mjs';

const [platform, appFile] = process.argv.slice(2);
const helper = process.argv.includes('--helper');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const example = join(root, 'example');
const pkg = 'net.scruter.rnexample';
const out = process.env.SCRUTER_CHECK_OUT ?? join(root, 'build/device-check');
mkdirSync(out, { recursive: true });

const batches = [];
const problems = [];
const team = { registered: 0, configs: 0, screens: [] };
const symbols = [];
const fail = (m) => problems.push(m);
const TEAM_TOKEN = `scr_tp_${'t'.repeat(43)}`;

function multipart(req, body) {
  const boundary = /boundary=(.*)$/.exec(req.headers['content-type'] ?? '')?.[1];
  const parts = {};
  for (const chunk of body.toString('latin1').split(`--${boundary}`)) {
    const name = /name="([^"]+)"/.exec(chunk)?.[1];
    if (name) parts[name] = chunk.slice(chunk.indexOf('\r\n\r\n') + 4, -2);
  }
  return parts;
}

// As the ingest does (docs/MOBILE.md §6.1): a batch sent again counts once. A process that died waiting for an answer sends it
// again from disk at the next launch.
const received = new Map();
let resent = 0;
const seen = [];
const server = createServer((req, res) => {
  seen.push(`${req.method} ${req.url}`);
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const answer = (code, body) => {
      res.statusCode = code;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(body ?? {}));
    };
    let body = Buffer.concat(chunks);
    if (req.headers['content-encoding'] === 'gzip') body = gunzipSync(body);
    const path = req.url.split('?')[0];
    if (path === '/m/v1/config') {
      return answer(200, { v: 1, on: 1, e: 'e1', tz: 'Europe/Paris', aa: 100, cr: 1, xs: ['Ignored*'], tp: 1, ttl: 3600 });
    }
    if (path === '/m/v1/batch') {
      const json = JSON.parse(body.toString('utf8'));
      for (const e of validate('batch', json)) fail(`schema: ${e}`);
      const items = JSON.stringify([json.e, json.x, json.cr]);
      if (received.has(json.b)) {
        resent++;
        if (received.get(json.b) !== items) fail(`batch ${json.b} changed when it was sent again`);
        return answer(202);
      }
      received.set(json.b, items);
      batches.push(json);
      return answer(202);
    }
    if (path === '/m/v1/team/register') {
      const json = JSON.parse(body.toString('utf8'));
      for (const e of validate('team-register', json)) fail(`team-register: ${e}`);
      team.registered++;
      return answer(201, { phone_id: 'p1', device_token: TEAM_TOKEN, name: 'Test phone' });
    }
    if (path === '/m/v1/team/config') {
      team.configs++;
      return answer(200, { phone_id: 'p1', captured: [], retake: [], max_bytes: 2000000, max_height: 10000, ttl: 600 });
    }
    if (path === '/m/v1/team/screens') {
      const parts = multipart(req, body);
      const meta = JSON.parse(Buffer.from(parts.meta ?? '{}', 'latin1').toString('utf8'));
      const tree = JSON.parse(Buffer.from(parts.tree ?? '{}', 'latin1').toString('utf8'));
      for (const e of validate('team-screen', meta, 'meta')) fail(`team meta: ${e}`);
      for (const e of validate('team-screen', tree, 'tree')) fail(`team tree: ${e}`);
      team.screens.push({ meta, tree, image: (parts.image ?? '').length });
      return answer(202, { id: `s${team.screens.length}` });
    }
    if (path === '/m/v1/symbols/missing') {
      const json = JSON.parse(body.toString('utf8'));
      return answer(200, { missing: json.files });
    }
    if (path === '/m/v1/symbols') {
      const json = JSON.parse(body.toString('utf8'));
      for (const e of validate('symbols', json, 'upload')) fail(`symbols: ${e}`);
      symbols.push(json);
      return answer(201, {
        id: `f${symbols.length}`,
        upload: { method: 'PUT', url: `http://127.0.0.1:8787/put/${symbols.length}`, headers: {}, expires_at: 'soon' },
      });
    }
    if (req.method === 'PUT' || /\/complete$/.test(path)) return answer(202);
    fail(`unexpected request ${req.method} ${req.url}`);
    answer(404);
  });
});
await new Promise((r) => server.listen(8787, '0.0.0.0', r));

// Never a synchronous child here: this process is also the server the app and the CLI talk to.
const child = (cmd, args, { quiet = false, ...options } = {}) =>
  new Promise((resolve) => {
    let stdout = '';
    const c = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'], ...options });
    const timer = setTimeout(() => c.kill('SIGKILL'), 600000);
    c.stdout.on('data', (d) => {
      stdout += d;
      if (!quiet) process.stdout.write(d);
    });
    c.on('close', (status) => {
      clearTimeout(timer);
      resolve({ status, stdout });
    });
  });

const flow = async (name, attempts = 2) => {
  for (let i = 1; ; i++) {
    const r = await child('maestro', ['test', join(example, `.maestro/${name}.yaml`), '--format', 'junit', '--output', join(out, `${name}.xml`), '--debug-output', join(out, name)]);
    if (r.status === 0) return;
    // Where the app stands when a flow cannot see it.
    if (platform === 'ios') await child('sample', ['ScruterExample', '2', '-file', join(out, `${name}-${i}-sample.txt`)], { quiet: true });
    if (i >= attempts) {
      fail(`maestro flow ${name} failed`);
      return;
    }
  }
};
const quiet = { quiet: true };
const adb = async (...a) => (await child('adb', a, quiet)).stdout.trim();
const simctl = async (...a) => (await child('xcrun', ['simctl', ...a], quiet)).stdout.trim();
const install = () => (platform === 'android' ? adb('install', '-r', appFile) : simctl('install', 'booted', appFile));
const stopApp = () => (platform === 'android' ? adb('shell', 'am', 'force-stop', pkg) : simctl('terminate', 'booted', pkg));
const launchApp = () =>
  platform === 'android' ? adb('shell', 'monkey', '-p', pkg, '-c', 'android.intent.category.LAUNCHER', '1') : simctl('launch', 'booted', pkg);
const home = () => (platform === 'android' ? adb('shell', 'input', 'keyevent', 'KEYCODE_HOME') : simctl('launch', 'booted', 'com.apple.Preferences'));
const settled = async (test, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (test()) return true;
    await sleep(500);
  }
  return test();
};
const until = async (test, ms, what) => {
  if (await settled(test, ms)) return true;
  fail(`timeout: ${what}`);
  return false;
};

const all = (key) => batches.flatMap((b) => b[key] ?? []);

await install();

// The first launch reads the configuration; Advanced analytics applies from the next session.
await launchApp();
await sleep(8000);
await stopApp();
await sleep(1000);

await flow('journey');
await sleep(2000);
await home();
// What the journey queued leaves with the 30-second timer or the background flush. On a simulator with every core busy, a
// backgrounded app can sit at the lowest priority until its time runs out (docs/MOBILE.md §21). The queue is on disk and goes
// at the next launch, the SDK's own fallback: taken once and said. Every check below stands, whichever way the data came.
const journeyArrived = () =>
  all('e').some((e) => e.k === 'event' && e.n === 'Add to cart') &&
  all('e').some((e) => e.k === 'screen' && e.n === 'Settings') &&
  all('x').some((v) => v.f?.some((f) => f.s === 'Delivery' && f.ok === 1)) &&
  all('cr').some((c) => c.k === 'nonfatal');
const sentRunning = await settled(journeyArrived, 60000);
const journeyPath = sentRunning ? 'sent by the running app' : 'not sent within 60 s: relaunched, sent at the next launch';
console.log(`the journey's data: ${journeyPath}`);
writeFileSync(join(out, 'journey-path.txt'), `${journeyPath}\n`);
if (!sentRunning) {
  await stopApp();
  await sleep(1000);
  await launchApp();
}
await until(() => all('e').some((e) => e.k === 'event' && e.n === 'Add to cart'), 45000, 'the journey\'s events');
await until(() => all('x').length > 3, 45000, 'the analysed screen views');
// A journey that was retried has sent its first half already: wait for its end.
await until(() => all('e').some((e) => e.k === 'screen' && e.n === 'Settings'), 45000, 'the last screen');
await until(() => all('x').some((v) => v.f?.some((f) => f.s === 'Delivery' && f.ok === 1)), 45000, 'the sent form');

// Sessions, screens, events.
const sdk = new Set(batches.map((b) => b.sdk));
if (sdk.size !== 1 || ![...sdk][0].startsWith('react_native/')) fail(`sdk field: ${[...sdk]}`);
const session = all('s')[0];
if (session?.p !== platform) fail(`platform: ${session?.p}`);
const screens = all('e').filter((e) => e.k === 'screen').map((e) => e.n);
for (const name of ['Home', 'Products', 'Product', 'Checkout', 'Settings']) {
  if (!screens.includes(name)) fail(`no screen ${name} in ${screens}`);
}
if (screens.some((n) => !['Home', 'Products', 'Product', 'Checkout', 'Settings'].includes(n))) fail(`foreign screen in ${screens}`);
if (JSON.stringify(all('e')).includes('"id"')) fail('a route param reached an event');
const added = all('e').find((e) => e.k === 'event' && e.n === 'Add to cart');
if (added?.$?.c !== 'EUR' || added?.$?.a !== 49) fail(`revenue: ${JSON.stringify(added)}`);
const hello = all('e').find((e) => e.k === 'event' && e.n === 'Hello');
if (hello?.p?.n !== '1') fail(`props: ${JSON.stringify(hello)}`);

// What a call costs on the JS thread, on this runtime.
console.log('JS thread:', JSON.stringify(all('e').filter((e) => e.n === 'SDK timing').slice(-2).map((e) => e.p)));

// Taps: identity by testID and nativeID, list positions, masks, ignored areas, scroll, forms.
const views = all('x');
const latest = new Map();
for (const v of views) {
  const key = v.k;
  const seen = latest.get(key) ?? { ...v, c: [] };
  latest.set(key, { ...v, c: [...seen.c, ...(v.c ?? [])] });
}
const merged = [...latest.values()];
const taps = merged.flatMap((v) => (v.c ?? []).map((c) => ({ screen: v.n, selector: c[0], index: c[1], kind: c[2], flags: c[6] })));
writeFileSync(join(out, 'taps.json'), JSON.stringify(taps, null, 1));
const tap = (screen, part) => taps.find((t) => t.screen === screen && t.selector.includes(part));
for (const [screen, part] of [['Home', '#open_products'], ['Home', '#welcome'], ['Products', '#add_to_cart'], ['Product', '#address'], ['Product', '#buy'], ['Checkout', '#submit']]) {
  if (!tap(screen, part)) fail(`no tap on ${part} in ${screen}: ${JSON.stringify(taps.filter((t) => t.screen === screen))}`);
}
if (tap('Home', '#open_products')?.kind !== 'button') fail(`a Pressable is not a button: ${JSON.stringify(tap('Home', '#open_products'))}`);
if (tap('Home', '#open_products')?.flags & 1) fail('a press counted as a dead tap');
if (taps.some((t) => t.selector.includes('ignored'))) fail('a tap inside an ignored area was collected');
const carts = taps.filter((t) => t.selector.includes('#add_to_cart'));
if (new Set(carts.map((t) => t.selector)).size !== 1) fail(`items of a list do not share a selector: ${JSON.stringify(carts)}`);
if (new Set(carts.map((t) => t.index)).size < 2) fail(`list positions: ${JSON.stringify(carts)}`);
if (carts[0] && carts[0].index !== 2) fail(`FlatList item position: ${JSON.stringify(carts[0])} (the third row)`);
const product = merged.find((v) => v.n === 'Product');
if (!product || product.sd < 100) fail(`scroll depth: ${product?.sd}`);
if (!product?.at?.some((ms) => ms > 0)) fail('no time per band');
const checkout = merged.filter((v) => v.n === 'Checkout').flatMap((v) => v.f ?? []);
const form = checkout.find((f) => f.s === 'Delivery' && f.ok === 1) ?? checkout.find((f) => f.s === 'Delivery');
if (!form) fail(`no form Delivery: ${JSON.stringify(checkout)}`);
else {
  const fields = form.fd.map((f) => f[0]);
  writeFileSync(join(out, 'form.json'), JSON.stringify(form, null, 1));
  if (!fields.includes('postal_code')) fail(`no field postal_code: ${fields}`);
  if (fields.includes('password') || fields.some((k) => /password/i.test(k))) fail(`a password field was collected: ${fields}`);
  if (!fields.includes('gift')) fail(`no choice gift: ${fields}`);
  if (form.ok !== 1) fail(`form not sent: ${JSON.stringify(form)}`);
  const postal = form.fd.find((f) => f[0] === 'postal_code');
  if (postal && postal[6] < 1) fail(`field error not counted: ${JSON.stringify(postal)}`);
}
if (JSON.stringify(batches).includes('secret')) fail('a typed value left the phone');

// A non-fatal error, then a fatal one: one report, in JavaScript, with the bundle's frames and breadcrumbs.
await until(() => all('cr').some((c) => c.k === 'nonfatal'), 30000, 'the non-fatal error');
const soft = all('cr').find((c) => c.k === 'nonfatal');
if (soft?.src !== 'js') fail(`non-fatal: ${JSON.stringify(soft)}`);
// Exactly once, whichever way the data came: an item in two batches would count twice.
const twice = (keys) => keys.filter((k, i) => keys.indexOf(k) !== i);
for (const k of twice(all('e').map((e) => JSON.stringify(e)))) fail(`an event arrived twice: ${k}`);
for (const k of twice(all('cr').map((c) => c.id))) fail(`a report arrived twice: ${k}`);
console.log(`${batches.length} batches, ${resent} sent again and counted once`);
await stopApp();
await sleep(1000);
const crashesBefore = all('cr').filter((c) => c.k === 'crash').length;
await flow('crash');
await sleep(4000);
await stopApp();
await sleep(1000);
await launchApp();
await until(() => all('cr').filter((c) => c.k === 'crash').length > crashesBefore, 60000, 'the fatal error\'s report');
await sleep(4000);
const fatal = all('cr').filter((c) => c.k === 'crash');
writeFileSync(join(out, 'crash.json'), JSON.stringify(fatal, null, 1));
if (fatal.length !== 1) fail(`${fatal.length} reports for one crash: ${fatal.map((c) => `${c.src}:${c.ex?.type}`)}`);
const crash = fatal[0];
if (crash) {
  if (crash.src !== 'js') fail(`crash source ${crash.src}`);
  if (crash.ex?.type !== 'TypeError') fail(`crash type: ${JSON.stringify(crash.ex)}`);
  if (!crash.bun) fail('no bundle id in the crash report');
  if (helper && !/^[0-9a-f-]{36}$/.test(crash.bun)) fail(`the Metro helper's id is missing: ${crash.bun}`);
  if (!helper && !crash.bun.startsWith(`rn-${platform}-`)) fail(`default bundle id: ${crash.bun}`);
  if (crash.scr !== 'Settings') fail(`crash screen: ${crash.scr}`);
  if (!crash.bc?.some((b) => b.k === 'screen' && b.n === 'Settings')) fail(`breadcrumbs: ${JSON.stringify(crash.bc)}`);
  const frames = crash.th?.[0]?.f ?? [];
  if (!frames.some((f) => f.ia === 1 && f.l >= 1)) fail(`no bundle frame: ${JSON.stringify(frames.slice(0, 3))}`);
  const crashed = all('s').filter((s) => s.id === crash.s && s.c?.cr === 1);
  if (crashed.length === 0) fail('the crashed session is not marked');
}

// The symbols of that very build: the CLI finds the map, and the map resolves the crash.
const map = platform === 'android' ? 'android/app/build/generated/sourcemaps/react/release/index.android.bundle.map' : 'main.jsbundle.map';
if (!existsSync(join(example, map))) fail(`no source map at ${map}`);
const cli = await child('node', [join(root, 'cli/index.js'), 'symbols', 'upload', '--app', 'EXAMPLE1', '--root', example, '--platform', platform, '--api', 'http://127.0.0.1:8787', '--strict', ...(platform === 'ios' ? ['--no-native'] : [])], {
  env: { ...process.env, SCRUTER_UPLOAD_TOKEN: `scr_up_${'a'.repeat(43)}` },
});
if (cli.status !== 0) fail(`the CLI failed: ${cli.stdout}`);
if (cli.stdout.includes('not composed')) fail('the CLI saw an uncomposed Hermes map');
const sourceMap = symbols.find((s) => s.kind === 'source_map');
if (!sourceMap) fail('the CLI sent no source map');
if (crash && sourceMap && sourceMap.debug_id !== crash.bun) fail(`debug ids differ: ${sourceMap.debug_id} / ${crash.bun}`);
if (crash && existsSync(join(example, map))) {
  const frame = crash.th[0].f.find((f) => f.ia === 1 && f.l >= 1);
  const lookup = (column) =>
    spawnSync('node', ['node_modules/metro-symbolicate/src/index.js', map, String(frame.l), String(column)], { cwd: example, encoding: 'utf8' }).stdout.trim();
  const zero = lookup(frame.co);
  const one = lookup(Math.max(0, frame.co - 1));
  console.log(`crash frame ${JSON.stringify(frame)}\n  at ${frame.co}: ${zero}\n  at ${frame.co - 1}: ${one}`);
  if (![zero, one].some((s) => /Settings|explodeNow/.test(s))) fail(`the source map does not resolve the crash: ${zero} / ${one}`);
}

// Team phones: the QR code, on a phone whose app is not running, and the capture of a masked screen.
await stopApp();
await sleep(1000);
await flow('qr');
await until(() => team.registered > 0, 45000, 'the team phone\'s registration');
await sleep(3000);
await stopApp();
await sleep(1000);
await flow('team');
await until(() => team.screens.some((s) => s.meta.screen === 'Product'), 90000, 'the captured screen');
writeFileSync(join(out, 'team.json'), JSON.stringify(team.screens.map((s) => ({ ...s.meta, nodes: s.tree.nodes })), null, 1));
const captured = team.screens.find((s) => s.meta.screen === 'Product');
if (captured) {
  const masked = captured.tree.nodes.find((n) => n.s.includes('#address'));
  if (!masked || masked.m !== 1 || masked.l) fail(`the masked element: ${JSON.stringify(masked)}`);
  if (/Morgan|Inside a mask/.test(JSON.stringify(captured.tree))) fail('a masked text reached the tree');
  if (captured.tree.nodes.some((n) => n.s.includes('ignored'))) fail('an ignored element reached the tree');
  // react-native-webview, with a role that says otherwise: the native layer's kind, masked, without a label.
  const web = captured.tree.nodes.filter((n) => n.k === 'web' || n.k === 'media');
  if (web.length === 0 || web.some((n) => n.m !== 1 || n.l)) fail(`the web view: ${JSON.stringify(web)} in ${JSON.stringify(captured.tree.nodes.map((n) => [n.s, n.k]))}`);
  if (captured.tree.nodes.some((n) => n.s.includes('#web') && n.k === 'image')) fail('the role relabelled the web view\'s host');
  if (!captured.tree.nodes.some((n) => n.s.includes('#buy'))) fail(`a scroll view of tall blocks was not captured whole: ${captured.meta.height} px high`);
  if (captured.image < 1000) fail(`image of ${captured.image} bytes`);
}
const teamSessions = all('s').filter((s) => s.tm === 1);
if (teamSessions.length === 0) fail('team sessions are not flagged');

// The user's choice: after it, nothing.
await flow('optout');
await sleep(3000);
const after = batches.length;
await launchApp();
await sleep(6000);
if (batches.length !== after) fail(`${batches.length - after} batches after the opt-out`);

if (platform === 'android') {
  const times = (await adb('logcat', '-d', '-s', 'Scruter:D')).split('\n').map((l) => /tap .*: (\d+) µs, (\d+) elements/.exec(l)).filter(Boolean);
  const us = times.map((m) => Number(m[1])).sort((a, b) => a - b);
  console.log(`identity of a tap: median ${us[us.length >> 1]} µs, worst ${us[us.length - 1]} µs, on ${times[0]?.[2]} elements`);
}
writeFileSync(join(out, 'batches.json'), JSON.stringify(batches, null, 1));
server.close();
console.log(`${batches.length} batches, ${all('e').length} events, ${views.length} analysed screen views, ${taps.length} taps, ${team.screens.length} captures`);
// What the app said: the SDK logs in this build (`debug: true`).
if (platform === 'android') {
  const log = await adb('logcat', '-d', '-s', 'Scruter:*', 'ReactNativeJS:*', 'AndroidRuntime:E');
  writeFileSync(join(out, 'logcat.txt'), log);
  if (problems.length) console.log(log.split('\n').slice(-120).join('\n'));
} else {
  const log = await child('xcrun', ['simctl', 'spawn', 'booted', 'log', 'show', '--last', '20m', '--style', 'compact', '--predicate', `process == "ScruterExample"`], quiet);
  writeFileSync(join(out, 'system.log'), log.stdout);
  if (problems.length) console.log(log.stdout.split('\n').slice(-120).join('\n'));
}
console.log(`requests: ${seen.length}, first: ${seen.slice(0, 5).join(', ')}`);
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n${problems.join('\n')}`);
  process.exit(1);
}
console.log('device check passed');
process.exit(0);
