#!/usr/bin/env node
// Scruter CMP in the example's debug build (setup.mjs --cmp --check) served by Metro, as a developer runs it: a
// JavaScript reload is a development tool (a release build has none). On an emulator or a simulator, against the local
// stub of the ingest (../ios/scripts/cmp_stub_ingest.py, serving protocol/cmp/bodies): first launch, decision, whenReady
// and onChange in JavaScript, the preferences, a withdrawal, a JavaScript reload without a second listener, a returning
// visitor, the debug reset. Every body the app sent is checked against protocol/schema, with `cv` naming the wrapper.
//   node scripts/cmp-device-check.mjs android|ios <app file>
// Shared with the Flutter example: SCRUTER_CMP_FLOWS (the Maestro flows' directory), SCRUTER_CMP_APP (the app id),
// SCRUTER_CMP_SDK (`react_native` or `flutter`).
import { spawn } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { validate } from '../../protocol/validate.mjs';

const [platform, appFile] = process.argv.slice(2);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const flows = process.env.SCRUTER_CMP_FLOWS ?? join(root, 'example/.maestro/cmp');
const pkg = process.env.SCRUTER_CMP_APP ?? 'net.scruter.rnexample';
const sdk = process.env.SCRUTER_CMP_SDK ?? 'react_native';
const out = resolve(process.env.SCRUTER_CHECK_OUT ?? join(root, 'build/cmp-device-check'));
const bodies = join(out, 'bodies');
const PORT = 8765;
mkdirSync(bodies, { recursive: true });

const problems = [];
const fail = (m) => problems.push(m);

const child = (cmd, args, { quiet = false, ...options } = {}) =>
  new Promise((done) => {
    let stdout = '';
    const c = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'], ...options });
    const timer = setTimeout(() => c.kill('SIGKILL'), 600000);
    c.stdout.on('data', (d) => {
      stdout += d;
      if (!quiet) process.stdout.write(d);
    });
    c.on('close', (status) => {
      clearTimeout(timer);
      done({ status, stdout });
    });
  });
const quiet = { quiet: true };
const adb = async (...a) => (await child('adb', a, quiet)).stdout.trim();
const simctl = async (...a) => (await child('xcrun', ['simctl', ...a], quiet)).stdout.trim();

const stub = spawn('python3', [join(root, '../ios/scripts/cmp_stub_ingest.py'), String(PORT), bodies], { stdio: 'inherit' });
const received = async () => (await (await fetch(`http://127.0.0.1:${PORT}/_stub/received`)).json());
for (let i = 0; i < 50; i++) {
  try {
    await received();
    break;
  } catch {
    await sleep(200);
  }
}

// Metro serves the debug build's bundle, and reloads it.
const metro = spawn('npx', ['react-native', 'start', '--port', '8081'], { cwd: join(root, 'example'), stdio: ['ignore', 'ignore', 'inherit'], detached: true });
// Metro may listen on IPv4 or only on IPv6 (`localhost` with Node 17+): the app is pointed at the address that answers.
let metroHost = null;
for (let i = 0; i < 120 && !metroHost; i++) {
  for (const host of ['127.0.0.1', '[::1]']) {
    try {
      if ((await (await fetch(`http://${host}:8081/status`)).text()).includes('running')) {
        metroHost = host;
        break;
      }
    } catch {
      // Not up yet.
    }
  }
  if (!metroHost) await sleep(1000);
}
if (!metroHost) fail('Metro did not answer on 127.0.0.1:8081 or [::1]:8081');
// Metro's first bundle takes minutes on a CI runner (the first flow gave up on « Bundling 96% »): it is built before
// the app asks for it.
if (metroHost) {
  const started = Date.now();
  const url = `http://${metroHost}:8081/index.bundle?platform=${platform}&dev=true&minify=false`;
  const r = await child('curl', ['-gsS', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '590', url], quiet);
  console.log(`Metro's ${platform} bundle: HTTP ${r.stdout || r.status} in ${Math.round((Date.now() - started) / 1000)} s`);
}
if (platform === 'android') {
  // The app's 127.0.0.1 is the emulator's: the stub's port reaches the host, its media URLs too; Metro's as well.
  await adb('reverse', `tcp:${PORT}`, `tcp:${PORT}`);
  await adb('reverse', 'tcp:8081', 'tcp:8081');
  await adb('uninstall', pkg);
  await adb('install', '-r', appFile);
} else {
  await simctl('uninstall', 'booted', pkg);
  await simctl('install', 'booted', appFile);
  // The debug build asks `localhost` by default (React Native 0.73 on CI never reached Metro): name the address.
  if (metroHost) await simctl('spawn', 'booted', 'defaults', 'write', pkg, 'RCT_jsLocation', `${metroHost}:8081`);
}

/** What the screen showed when a flow failed: its image and the tree Maestro saw. */
const evidence = async (name) => {
  writeFileSync(join(out, `${name}-hierarchy.json`), (await child('maestro', ['hierarchy'], quiet)).stdout);
  if (platform === 'android') await child('sh', ['-c', `adb exec-out screencap -p > '${join(out, `${name}.png`)}'`], quiet);
  else await simctl('io', 'booted', 'screenshot', join(out, `${name}.png`));
};

const flow = async (name, attempts = 2) => {
  for (let i = 1; ; i++) {
    const r = await child('maestro', ['test', '--format', 'junit', '--output', join(out, `${name}.xml`), '--debug-output', join(out, name), '--test-output-dir', join(out, 'shots'), join(flows, `${name}.yaml`)], { cwd: out });
    if (r.status === 0) return true;
    await evidence(`${name}-${i}`);
    if (i >= attempts) {
      fail(`maestro flow ${name} failed`);
      return false;
    }
  }
};

// One decision per flow step: retrying a flow after its decision would send a second proof, so a flow runs once.
const firstOk = await flow('first', 1);
await sleep(3000);
if (firstOk) await flow('reload', 1);
await sleep(3000);
if (platform === 'android') await adb('shell', 'am', 'force-stop', pkg);
else await simctl('terminate', 'booted', pkg);
await sleep(1500);
await flow('relaunch', 1);
await sleep(6000);

const all = await received();
writeFileSync(join(out, 'received.json'), JSON.stringify(all, null, 1));
const hits = all.filter((r) => r.schema === 'cmp-hit').map((r) => r.body);
const proofs = all.filter((r) => r.schema === 'cmp-consent').map((r) => r.body);

for (const r of all) {
  for (const e of validate(r.schema, r.body)) fail(`${r.schema}: ${e} in ${JSON.stringify(r.body)}`);
  if (r.schema !== 'cmp-sdks') {
    if (!new RegExp(`^${sdk}/\\d+\\.\\d+\\.\\d+`).test(r.body.cv ?? '')) fail(`cv ${r.body.cv}: not ${sdk}/<version>`);
    if (r.body.p !== platform) fail(`p ${r.body.p}`);
  }
}
for (const f of readdirSync(bodies)) {
  const schema = f.replace(/--.*/, '');
  for (const e of validate(schema, JSON.parse(readFileSync(join(bodies, f), 'utf8')))) fail(`${f}: ${e}`);
}
if (!hits.some((h) => h.d === 1)) fail(`no opening with the sheet shown: ${JSON.stringify(hits)}`);
// accept_all (banner), withdraw (preferences), accept_all (preferences, after the reload), reject_all (banner, after the
// reset): one proof each, never two for one decision.
const decisions = proofs.map((p) => `${p.c}/${p.o}`);
const expected = ['accept_all/banner', 'withdraw/preferences', 'accept_all/preferences', 'reject_all/banner'];
if (JSON.stringify(decisions) !== JSON.stringify(expected)) fail(`proofs ${JSON.stringify(decisions)}, expected ${JSON.stringify(expected)}`);
if (new Set(proofs.slice(0, 3).map((p) => p.i)).size !== 1) fail('the consent id changed between the decisions of one device');
if (proofs[3] && proofs[3].i === proofs[0]?.i) fail('the debug reset kept the consent id');

if (platform === 'android') {
  writeFileSync(join(out, 'logcat.txt'), await adb('logcat', '-d', '-s', 'ScruterCMP:*', 'ReactNativeJS:*', 'flutter:*', 'AndroidRuntime:E'));
} else {
  const log = await child('xcrun', ['simctl', 'spawn', 'booted', 'log', 'show', '--last', '20m', '--style', 'compact', '--predicate', 'subsystem == "net.scruter.cmp" OR process == "Runner" OR process == "ScruterExample"'], quiet);
  writeFileSync(join(out, 'system.log'), log.stdout);
}
stub.kill();
try {
  process.kill(-metro.pid);
} catch {
  // Gone already.
}
console.log(`${hits.length} hits, ${proofs.length} proofs (${decisions.join(', ')}), ${all.length - hits.length - proofs.length} SDK reports`);
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n${problems.join('\n')}`);
  process.exit(1);
}
console.log('CMP device check passed');
process.exit(0);
