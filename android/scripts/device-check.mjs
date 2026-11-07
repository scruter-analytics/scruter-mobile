#!/usr/bin/env node
// The R8 release build of the sample on a real Android (an emulator in the CI), against a local server that answers
// like the ingest and checks every batch with the protocol kit: screens from fragments and Navigation Compose, taps
// through the semantics tree, a Java crash with the R8 mapping id, a native crash read from a real tombstone. Prints the
// SDK's own timings from Logcat.
//
//   ./gradlew :sample:assembleRelease -Pscruter.selfCheck=http://10.0.2.2:8787
//   node scripts/device-check.mjs sample/build/outputs/apk/release/sample-release.apk
import { createServer } from 'node:http';
import { gunzipSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { validate } from '../../protocol/validate.mjs';

const apk = process.argv[2];
const pkg = 'net.scruter.sample';
const adb = (...a) => execFileSync('adb', a, { encoding: 'utf8', timeout: 120000 }).trim();
const shell = (cmd) => adb('shell', cmd);
const batches = [];
const problems = [];
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    if (req.url.startsWith('/m/v1/config')) {
      res.end(JSON.stringify({ v: 1, on: 1, e: 'e1', tz: 'Europe/Paris', aa: 100, cr: 1, xs: [], tp: 0, ttl: 3600 }));
      return;
    }
    let body = Buffer.concat(chunks);
    if (req.headers['content-encoding'] === 'gzip') body = gunzipSync(body);
    const json = JSON.parse(body.toString('utf8'));
    for (const e of validate('batch', json)) problems.push(`schema: ${e}`);
    batches.push(json);
    res.statusCode = 202;
    res.end('{}');
  });
});
await new Promise((r) => server.listen(8787, '0.0.0.0', r));

// -S: a new process, so that the activity's onCreate runs with these extras.
const start = (activity, extra = '') => shell(`am start -S -W -n ${pkg}/.${activity} ${extra}`);
const home = () => shell('input keyevent KEYCODE_HOME');
const size = shell('wm size').match(/(\d+)x(\d+)/);
const [w, h] = [Number(size[1]), Number(size[2])];
const api = Number(shell('getprop ro.build.version.sdk'));

adb('install', '-r', apk);
shell('logcat -c');

// A first launch: the configuration arrives. A session samples Advanced analytics from the copy it finds.
start('HomeActivity');
await sleep(4000);
home();
await sleep(3000);

// Views: a fragment with a list.
start('HomeActivity');
await sleep(4000);
shell(`input tap ${w >> 1} ${h - (h >> 2)}`);
await sleep(1500);
shell(`input swipe ${w >> 1} ${h - 300} ${w >> 1} 400 300`);
await sleep(1500);
home();
await sleep(4000);

// Compose: Navigation Compose, a lazy list, taps through semantics.
start('ComposeShopActivity');
await sleep(4000);
shell(`input tap ${w >> 1} ${h >> 2}`);
await sleep(2500);
home();
await sleep(4000);

// A Java crash, sent at the next launch.
start('HomeActivity', '--es scruter_crash java');
await sleep(5000);
start('HomeActivity');
await sleep(4000);
home();
await sleep(4000);

// A native crash: a tombstone from Android 12.
start('HomeActivity', '--es scruter_crash native');
await sleep(8000);
start('HomeActivity');
await sleep(4000);
home();
await sleep(4000);

// What a tap's identity costs on a 2 000-element screen, once the code is warm.
start('StressActivity');
await sleep(3000);
for (let i = 0; i < 12; i++) {
  shell(`input tap 10 ${h >> 1}`);
  await sleep(300);
}
await sleep(1000);
home();
await sleep(2000);

const events = batches.flatMap((b) => b.e || []);
const views = batches.flatMap((b) => b.x || []);
const crashes = batches.flatMap((b) => b.cr || []);
const screens = [...new Set(events.filter((e) => e.k === 'screen').map((e) => e.n))];
const taps = views.flatMap((v) => (v.c || []).map((c) => ({ screen: v.n, selector: c[0], index: c[1], kind: c[2] })));
const expect = (ok, what) => { if (!ok) problems.push(what); };

console.log(`API ${api}: ${batches.length} batches, screens ${JSON.stringify(screens)}`);
console.log('taps', JSON.stringify(taps.slice(0, 4)));
console.log('crashes', JSON.stringify(crashes.map((c) => ({ k: c.k, ex: c.ex, map: c.map, frames: c.th[0].f.slice(0, 3), img: (c.img || []).slice(0, 2) }))));
expect(screens.includes('Catalog'), 'the fragment screen (R8: keepnames rule)');
expect(screens.includes('shop'), 'the Navigation Compose route');
expect(taps.some((t) => t.screen === 'Catalog' && t.selector === '#products/TextView'), 'a tap on a RecyclerView cell, with its resource name');
expect(taps.some((t) => t.screen === 'shop' && t.selector === '#products/#product' && t.kind === 'cell'), 'a tap through the Compose semantics tree under R8');
const java = crashes.find((c) => c.ex.reason === 'Self-check crash');
expect(java, 'the Java crash report');
expect(java && /^[0-9a-f]+$/.test(java.map), 'the R8 mapping id in the report (Gradle plugin asset)');
if (api >= 31) {
  const native = crashes.find((c) => c.ex.sig === 'SIGSEGV');
  expect(native, 'the native crash report (ApplicationExitInfo tombstone)');
  expect(native && native.img && native.img.length > 0, 'binary images read from the tombstone');
}
expect(batches.some((b) => b.s.some((s) => s.bk === 'release' && s.p === 'android')), 'a release session');
expect(screens.includes('Stress'), 'the 2 000-element screen');

console.log('--- timings');
const log = adb('logcat', '-d', '-s', 'ScruterSample:I', 'Scruter:D').split('\n');
const us = (re) => log.map((l) => l.match(re)).filter(Boolean).map((m) => Number(m[1]));
const taps2000 = log.filter((l) => / µs, 2\d\d\d elements/.test(l)).map((l) => Number(l.match(/: (\d+) µs/)[1]));
console.log(`timings: start ${JSON.stringify(us(/start: (\d+) µs/))} µs; tap on ${log.map((l) => l.match(/µs, (\d+) elements/)).filter(Boolean).pop()?.[1]} elements ${JSON.stringify(taps2000)} µs`);
server.close();
if (problems.length) {
  console.error('--- problems');
  for (const p of problems) console.error(p);
  process.exit(1);
}
console.log('device check passed');
process.exit(0);
