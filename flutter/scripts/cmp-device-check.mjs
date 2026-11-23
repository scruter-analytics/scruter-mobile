#!/usr/bin/env node
// Scruter CMP in the example, on an emulator or a simulator, against the local stub of the ingest
// (../ios/scripts/cmp_stub_ingest.py, serving protocol/cmp/bodies): first launch, decision, whenReady and onChange in
// Dart, the preferences, a withdrawal, a hot restart without a second listener or a second engine, a returning
// visitor, the debug reset. The app runs under `flutter run` (debug), whose `R` is the hot restart. Every body the app
// sent is checked against protocol/schema, with `cv` naming the wrapper.
//   node scripts/cmp-device-check.mjs android|ios <device id>
import { spawn } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { validate } from '../../protocol/validate.mjs';

const [platform, device] = process.argv.slice(2);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const example = join(root, 'example');
const flows = join(example, '.maestro/cmp');
const app = platform === 'android' ? 'net.scruter.scruter_flutter_example' : 'net.scruter.scruterFlutterExample';
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
    const timer = setTimeout(() => c.kill('SIGKILL'), 900000);
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

if (platform === 'android') {
  await adb('reverse', `tcp:${PORT}`, `tcp:${PORT}`);
  await adb('uninstall', app);
} else {
  await simctl('uninstall', device, app);
}

// `flutter run`: its output tells when the app runs and when a hot restart is done; its input takes `R` and `q`.
const run = spawn(
  'flutter',
  ['run', '-d', device, '--debug', `--dart-define=SCRUTER_CMP_ENDPOINT=http://127.0.0.1:${PORT}`,
    // Scruter Analytics, started by the example too, talks to nothing here.
    '--dart-define=SCRUTER_ENDPOINT=http://127.0.0.1:9'],
  { cwd: example, stdio: ['pipe', 'pipe', 'inherit'] },
);
let output = '';
run.stdout.on('data', (d) => {
  output += d;
  process.stdout.write(d);
});
const waitFor = async (pattern, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (pattern.test(output)) return true;
    await sleep(500);
  }
  fail(`flutter run: no ${pattern} within ${ms / 1000} s`);
  return false;
};

/** What the screen showed when a flow failed: its image and the tree Maestro saw. */
const evidence = async (name) => {
  writeFileSync(join(out, `${name}-hierarchy.json`), (await child('maestro', ['hierarchy'], quiet)).stdout);
  if (platform === 'android') await child('sh', ['-c', `adb exec-out screencap -p > '${join(out, `${name}.png`)}'`], quiet);
  else await simctl('io', device, 'screenshot', join(out, `${name}.png`));
};

const flow = async (name) => {
  const r = await child(
    'maestro',
    ['test', '--format', 'junit', '--output', join(out, `${name}.xml`), '--debug-output', join(out, name), '-e', `APP_ID=${app}`, '--test-output-dir', join(out, 'shots'), join(flows, `${name}.yaml`)],
    { cwd: out },
  );
  if (r.status !== 0) {
    fail(`maestro flow ${name} failed`);
    await evidence(name);
  }
  return r.status === 0;
};

if (await waitFor(/Flutter run key commands|To hot restart/, 1200000)) {
  const firstOk = await flow('first');
  await sleep(3000);
  if (firstOk) {
    const before = output.length;
    run.stdin.write('R');
    const restarted = await waitFor(/Restarted application/, 120000);
    if (restarted && output.length > before) await flow('restart');
  }
}
run.stdin.write('q');
await sleep(3000);
run.kill();
await sleep(2000);
if (platform === 'android') await adb('shell', 'am', 'force-stop', app);
else await simctl('terminate', device, app);
await sleep(1500);
await flow('relaunch');
await sleep(6000);

const all = await received();
writeFileSync(join(out, 'received.json'), JSON.stringify(all, null, 1));
writeFileSync(join(out, 'flutter-run.txt'), output);
const hits = all.filter((r) => r.schema === 'cmp-hit').map((r) => r.body);
const proofs = all.filter((r) => r.schema === 'cmp-consent').map((r) => r.body);
for (const r of all) {
  for (const e of validate(r.schema, r.body)) fail(`${r.schema}: ${e} in ${JSON.stringify(r.body)}`);
  if (r.schema !== 'cmp-sdks') {
    if (!/^flutter\/\d+\.\d+\.\d+/.test(r.body.cv ?? '')) fail(`cv ${r.body.cv}: not flutter/<version>`);
    if (r.body.p !== platform) fail(`p ${r.body.p}`);
    if (r.body.dbg !== 1) fail('a debug build\'s beacon without dbg = 1');
  }
}
for (const f of readdirSync(bodies)) {
  const schema = f.replace(/--.*/, '');
  for (const e of validate(schema, JSON.parse(readFileSync(join(bodies, f), 'utf8')))) fail(`${f}: ${e}`);
}
if (!hits.some((h) => h.d === 1)) fail(`no opening with the sheet shown: ${JSON.stringify(hits)}`);
const decisions = proofs.map((p) => `${p.c}/${p.o}`);
const expected = ['accept_all/banner', 'withdraw/preferences', 'accept_all/preferences', 'reject_all/banner'];
if (JSON.stringify(decisions) !== JSON.stringify(expected)) fail(`proofs ${JSON.stringify(decisions)}, expected ${JSON.stringify(expected)}`);
if (new Set(proofs.slice(0, 3).map((p) => p.i)).size !== 1) fail('the consent id changed between the decisions of one device');
if (proofs[3] && proofs[3].i === proofs[0]?.i) fail('the debug reset kept the consent id');
// One engine per process: a hot restart starts nothing again (the native module warns of a second start).
// (Scruter Analytics, which the example starts too, logs its own "Scruter.start called twice".)
if (/ScruterCMP\.start called twice|start\(appId:\) called twice/.test(output)) fail('a second native start after the hot restart');

if (platform === 'android') writeFileSync(join(out, 'logcat.txt'), await adb('logcat', '-d', '-s', 'ScruterCMP:*', 'flutter:*', 'AndroidRuntime:E'));
stub.kill();
console.log(`${hits.length} hits, ${proofs.length} proofs (${decisions.join(', ')}), ${all.length - hits.length - proofs.length} SDK reports`);
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n${problems.join('\n')}`);
  process.exit(1);
}
console.log('CMP device check passed');
process.exit(0);
