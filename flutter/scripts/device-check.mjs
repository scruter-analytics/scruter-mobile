#!/usr/bin/env node
// The example's self-check on a real runtime (an emulator or a simulator in the CI), against a local server that answers
// like the ingest and the api and checks every payload with the protocol kit:
//
//   node scripts/device-check.mjs android debug|release <apk>
//   node scripts/device-check.mjs ios debug <Runner.app> <simulator udid>
//
// The app (lib/self_check.dart) drives itself with real pointer events. Debug: a team phone, whose screen images are saved
// in build/device-check/. Release: no team phone even with the key in the code, the timings of a release build.
import { createServer } from 'node:http';
import { gunzipSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { validate } from '../../protocol/validate.mjs';

const [platform, mode, app, udid] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '../build/device-check', `${platform}-${mode}`);
mkdirSync(out, { recursive: true });
const pkg = platform === 'android' ? 'net.scruter.scruter_flutter_example' : 'net.scruter.scruterFlutterExample';
const batches = [];
const images = [];
const problems = [];
const team = { registered: 0, byLink: 0, configs: 0 };
let configs = 0;
let selfCheck = null;
const check = (schema, value, def) => {
  for (const e of validate(schema, value, def)) problems.push(`${schema}: ${e}`);
};

function parts(body, boundary) {
  const out = {};
  const sep = Buffer.from(`--${boundary}`);
  let at = body.indexOf(sep);
  while (at >= 0) {
    const next = body.indexOf(sep, at + sep.length);
    if (next < 0) break;
    const part = body.subarray(at + sep.length + 2, next - 2);
    const head = part.indexOf('\r\n\r\n');
    const name = /name="([^"]+)"/.exec(part.subarray(0, head).toString())?.[1];
    out[name] = part.subarray(head + 4);
    at = next;
  }
  return out;
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    const path = req.url.split('?')[0];
    let body = Buffer.concat(chunks);
    if (path === '/m/v1/config') {
      configs++;
      res.end(JSON.stringify({ v: 1, on: 1, e: 'e1', tz: 'Europe/Paris', aa: 100, cr: 1, xs: [], tp: 1, ttl: 3600 }));
    } else if (path === '/m/v1/batch') {
      if (req.headers['content-encoding'] === 'gzip') body = gunzipSync(body);
      const json = JSON.parse(body.toString('utf8'));
      check('batch', json);
      batches.push(json);
      res.statusCode = 202;
      res.end('{}');
    } else if (path === '/self-check') {
      selfCheck = JSON.parse(body.toString('utf8'));
      res.end('{}');
    } else if (path === '/m/v1/team/register') {
      const reg = JSON.parse(body.toString('utf8'));
      team.registered++;
      if (reg.token) team.byLink++;
      check('team-register', reg);
      res.statusCode = 201;
      res.end(JSON.stringify({ phone_id: 'p1', device_token: `scr_tp_${'a'.repeat(43)}`, name: 'Test' }));
    } else if (path === '/m/v1/team/config') {
      team.configs++;
      res.end(JSON.stringify({ phone_id: 'p1', captured: [], retake: [], max_bytes: 2000000, max_height: 10000, ttl: 600 }));
    } else if (path === '/m/v1/team/screens') {
      const boundary = /boundary=(.+)$/.exec(req.headers['content-type'])[1];
      const p = parts(body, boundary);
      const meta = JSON.parse(p.meta.toString());
      const tree = JSON.parse(p.tree.toString());
      check('team-screen', meta, 'meta');
      check('team-screen', tree, 'tree');
      if (p.image[0] !== 0xff || p.image[1] !== 0xd8) problems.push('an image is not a JPEG');
      if (p.image.length > 2000000) problems.push('an image is over 2 MB');
      const name = `${images.length}-${meta.screen.replace(/\W+/g, '_')}`;
      writeFileSync(join(out, `${name}.jpg`), p.image);
      writeFileSync(join(out, `${name}.json`), JSON.stringify({ meta, tree }, null, 2));
      images.push({ meta, tree });
      res.statusCode = 202;
      res.end('{"id":"i1"}');
    } else {
      res.statusCode = 404;
      res.end('{}');
    }
  });
});
await new Promise((r) => server.listen(8787, '0.0.0.0', r));

const logs = [];
const run = (c, a, timeout = 180000) => execFileSync(c, a, { encoding: 'utf8', timeout }).trim();
// A simulator that has just booted migrates its data first, and a loaded runner takes minutes to serve a first launch.
const SIMULATOR_MS = 420000;
if (platform === 'android') {
  try {
    run('adb', ['uninstall', pkg]);
  } catch {}
  run('adb', ['install', '-r', app]);
  run('adb', ['shell', 'logcat', '-c']);
} else {
  run('xcrun', ['simctl', 'bootstatus', udid, '-b'], SIMULATOR_MS);
  run('xcrun', ['simctl', 'install', udid, app]);
}
const launch = () => {
  if (platform === 'android') run('adb', ['shell', 'monkey', '-p', pkg, '-c', 'android.intent.category.LAUNCHER', '1']);
  else run('xcrun', ['simctl', 'launch', udid, pkg], SIMULATOR_MS);
};
const stop = () => {
  if (platform === 'android') run('adb', ['shell', 'am', 'force-stop', pkg]);
  else run('xcrun', ['simctl', 'terminate', udid, pkg]);
};

// A first launch: the configuration arrives, and a debug build with its key becomes a team phone. A session samples
// Advanced analytics from the copy it finds, and a launch stopped before these answers leaves no copy and no token. A loaded
// runner takes seconds to reach `Scruter.start`, and a busy emulator can lose a launch: this waits for the answers, launches
// again after 40 seconds of silence, then lets the app keep them.
const answered = () => configs > 0 && (mode !== 'debug' || team.configs > 0);
let launches = 0;
while (launches < 3 && !answered()) {
  launch();
  launches++;
  const silence = Date.now() + 40000;
  while (Date.now() < silence && !answered()) await sleep(250);
}
console.log(`     first launch: ${launches} attempt(s)`);
await sleep(3000);
stop();
await sleep(1000);
batches.length = 0;
images.length = 0;
selfCheck = null;
launch();
const deadline = Date.now() + 180000;
while (Date.now() < deadline && !selfCheck) await sleep(500);
await sleep(4000);
// The last screen's state: at the flush, else with the 30-second timer when a batch was in flight at that moment.
const sent = () => batches.some((b) => (b.x ?? []).some((v) => v.n === 'Measure'));
for (let i = 0; i < 80 && !sent(); i++) await sleep(500);
if (platform === 'android') logs.push(...run('adb', ['logcat', '-d', '-v', 'brief', 'flutter:I', 'Scruter:D', 'AndroidRuntime:E', '*:S']).split('\n'));
writeFileSync(join(out, 'logs.txt'), logs.join('\n'));
writeFileSync(join(out, 'batches.json'), JSON.stringify(batches, null, 2));

// ---------------------------------------------------------------------------------------------------- the journey

const expect = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) problems.push(what);
};
expect(selfCheck !== null && !selfCheck.failed, `the self-check ran to its end${selfCheck?.failed ? `: ${selfCheck.failed}` : ''}`);
expect(!logs.some((l) => l.includes(`Process: ${pkg}`)), 'the app never crashed, on either launch');
const events = batches.flatMap((b) => b.e ?? []);
const views = batches.flatMap((b) => b.x ?? []);
const reports = batches.flatMap((b) => b.cr ?? []);
const raw = JSON.stringify(batches);
expect(batches.length > 0 && batches.every((b) => b.sdk === 'flutter/1.0.2'), 'batches name the SDK flutter/1.0.2');
const screens = events.filter((e) => e.k === 'screen').map((e) => e.n);
console.log('     screens:', screens.join(', '));
expect(['Home', '/product/:id', 'Checkout', 'Measure'].every((n) => screens.includes(n)), 'the screens have their route names');
expect(!screens.includes('Flutter') && !screens.includes('Main') && !screens.includes('Runner'), 'the host activity or controller is no screen');
expect(!/\/product\/\d/.test(raw), 'no route parameter anywhere');
expect(events.filter((e) => e.k === 'screen_end').every((e) => e.sc % 5 === 0), 'screen_end from Dart');
const home = views.filter((v) => v.n === 'Home').pop();
expect(home && home.sd > 0 && home.sd < 100, `scroll depth of a long list (${home?.sd})`);
expect(views.some((v) => v.n === 'Measure' && v.ch > 2000), 'a heavy page: its container found');
const event = events.find((e) => e.k === 'event' && e.n === 'Add to cart');
expect(event?.$?.c === 'EUR', 'a custom event with its revenue');
const taps = views.flatMap((v) => v.c ?? []);
expect(taps.some((t) => t[0].includes('#addToCart')), 'a tap on #addToCart');
expect(taps.some((t) => t[0].startsWith('#products/') && t[2] === 'cell'), 'a tap on a list cell, by position');
expect(taps.some((t) => t[6] === 1), 'a dead tap');
const form = views.flatMap((v) => v.f ?? []).filter((f) => f.s === 'Delivery').pop();
expect(form?.ok === 1 && form?.rf >= 1, `the form: refused then sent (${JSON.stringify({ ok: form?.ok, rf: form?.rf })})`);
const fields = form?.fd?.map((f) => f[0]) ?? [];
expect(fields.includes('postalCode') && fields.includes('email'), `its fields (${fields})`);
expect(!fields.some((f) => /password/i.test(f)), 'no password field');
expect(!raw.includes('jane@example') && !raw.includes('75011') && !raw.includes('hunter2'), 'never a value');
const dart = reports.find((r) => r.src === 'dart');
expect(dart?.k === 'nonfatal' && dart?.ex?.type === 'StateError', 'a Dart error, nonfatal');
expect((dart?.bc ?? []).some((b) => b.k === 'screen'), 'with its breadcrumbs');
if (mode === 'debug') {
  expect(team.registered - team.byLink === 1, `a debug build with its key becomes a team phone (${team.registered - team.byLink})`);
  expect(batches.every((b) => b.s.every((s) => s.bk === 'debug')), 'sessions flagged debug');
  expect(images.length >= 3, `screen images uploaded (${images.length})`);
  const checkout = images.find((i) => i.meta.screen === 'Checkout');
  const inputs = checkout?.tree.nodes.filter((n) => n.k === 'input') ?? [];
  expect(inputs.length >= 3 && inputs.every((n) => n.m === 1 && n.l === undefined), 'text inputs masked, without label');
  const product = images.find((i) => i.meta.screen === '/product/:id');
  expect(product && product.meta.height > product.tree.nodes[0].h / 2, 'the long screen is stitched');
  const tall = product ? Math.max(...product.tree.nodes.map((n) => n.y)) : 0;
  expect(tall > 1000, `elements of the whole screen in the tree (lowest at ${tall})`);
  const ids = images.flatMap((i) => i.tree.nodes.map((n) => n.s));
  expect(taps.filter((t) => t[6] !== 1).some((t) => ids.includes(t[0])), 'taps land on the elements of the tree');
} else {
  expect(team.registered === 0 && images.length === 0, 'a release build never takes an image, key or not');
  expect(batches.every((b) => b.s.every((s) => s.bk !== 'debug')), 'sessions of a release build');
}
console.log(`     Scruter.start: ${selfCheck?.startUs} µs on the main isolate`);
console.log(`     identity on a heavy screen: ${JSON.stringify(selfCheck?.tree)}`);
writeFileSync(join(out, 'timings.json'), JSON.stringify(selfCheck));

/** The native question of a team link (docs/MOBILE.md §3.12): the emulator's language is English. */
async function sayYes(until) {
  while (Date.now() < until) {
    // uiautomator gives up on a screen that keeps moving: the next try reads it.
    let screen = '';
    try {
      screen = run('adb', ['exec-out', 'uiautomator', 'dump', '/dev/tty']);
    } catch {}
    const b = /text="Add"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/.exec(screen);
    if (b) {
      run('adb', ['shell', 'input', 'tap', String((+b[1] + +b[3]) >> 1), String((+b[2] + +b[4]) >> 1)]);
      return true;
    }
    await sleep(500);
  }
  return false;
}

// The console's QR code: the phone's camera opens this link. In release on Android, the app was not running: the link waits
// for `Scruter.start`, asks the person holding the phone, then a release build, now a team phone, takes its images.
const link = `scruter-atmona02://team?t=scr_qr_${'a'.repeat(32)}`;
if (platform === 'android' && mode === 'release') {
  stop();
  selfCheck = null;
  run('adb', ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', `'${link}'`]);
  const until = Date.now() + 180000;
  expect(await sayYes(Date.now() + 60000), 'a QR code asks before it does anything');
  while (Date.now() < until && !selfCheck) await sleep(500);
  await sleep(3000);
  expect(team.byLink === 1, 'a QR code registers a phone, from a cold start');
  expect(images.length >= 3, `a release team phone takes images (${images.length})`);
  const form = images.find((i) => i.meta.screen === 'Checkout');
  expect(form?.tree.nodes.filter((n) => n.k === 'input').every((n) => n.m === 1 && n.l === undefined), 'masked in a release build too');
} else if (platform === 'ios') {
  // The native alert waits for a person, which nothing here is: a link alone registers nothing (the SDK's own tests say yes).
  expect(team.byLink === 0, 'Scruter.handleLink: a QR code through the plugin asks first');
}
server.close();
if (problems.length) {
  console.error(problems.slice(0, 30).join('\n'));
  process.exit(1);
}
console.log(`${platform} ${mode}: all good: ${batches.length} batches, ${views.length} analysed states, ${images.length} images`);
process.exit(0);
