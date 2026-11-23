#!/usr/bin/env node
// What Scruter CMP adds to the example's release build, and M2 (docs/CMP-MOBILE.md): an app carries only the native code
// of the modules its package.json takes. Builds the example (setup.mjs, already run) three times, Scruter Analytics
// alone, both modules, Scruter CMP alone, and checks each build for each module's code.
//   node scripts/cmp-size.mjs android|ios
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const platform = process.argv[2];
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const example = join(root, 'example');
const out = join(root, 'build');
mkdirSync(out, { recursive: true });
const run = (cmd, args, cwd, env = {}) => execFileSync(cmd, args, { cwd, stdio: 'inherit', env: { ...process.env, ...env } });

// What only each module's code holds: a path of its own protocol in the dex, a log line in the Swift binary (Swift keeps
// strings of 15 bytes or less inside the instructions).
const MARKERS =
  platform === 'android'
    ? { analytics: '/m/v1/batch', cmp: '/m/v1/cmp?a=' }
    : { analytics: 'event without a name: ignored', cmp: 'the CMP is off for this app (on: 0)' };
const VARIANTS = [
  { name: 'analytics', scruter: undefined, has: ['analytics'] },
  { name: 'both', scruter: { cmp: true }, has: ['analytics', 'cmp'] },
  { name: 'cmp', scruter: { cmp: true, analytics: false }, has: ['cmp'] },
];

function setModules(scruter) {
  const file = join(example, 'package.json');
  const p = JSON.parse(readFileSync(file, 'utf8'));
  if (scruter) p.scruter = scruter;
  else delete p.scruter;
  writeFileSync(file, `${JSON.stringify(p, null, 2)}\n`);
}

const contains = (buffer, text) => buffer.includes(Buffer.from(text, 'latin1'));

function size(path) {
  const s = statSync(path);
  if (!s.isDirectory()) return s.size;
  return readdirSync(path).reduce((n, f) => n + size(join(path, f)), 0);
}

function android() {
  const apk = join(example, 'android/app/build/outputs/apk/release/app-release.apk');
  run('./gradlew', ['--no-daemon', '--max-workers=3', ':app:assembleRelease'], join(example, 'android'), {
    ORG_GRADLE_PROJECT_reactNativeArchitectures: 'arm64-v8a',
  });
  const dex = execFileSync('sh', ['-c', `unzip -p '${apk}' 'classes*.dex'`], { maxBuffer: 1 << 30 });
  return { bytes: statSync(apk).size, code: dex.length, blob: dex };
}

function ios() {
  run('pod', ['install'], join(example, 'ios'), { RCT_NEW_ARCH_ENABLED: '1' });
  const derived = join(example, 'ios/build-size');
  run(
    'xcodebuild',
    ['-workspace', 'ScruterExample.xcworkspace', '-scheme', 'ScruterExample', '-configuration', 'Release', '-sdk', 'iphoneos',
      '-destination', 'generic/platform=iOS', '-derivedDataPath', derived, 'CODE_SIGNING_ALLOWED=NO', '-quiet', 'build'],
    join(example, 'ios'),
    { SOURCEMAP_FILE: join(example, 'main.jsbundle.map') },
  );
  const app = join(derived, 'Build/Products/Release-iphoneos/ScruterExample.app');
  // Stripped, as the App Store ships it (the build keeps its symbols for the dSYM).
  const stripped = join(out, 'ScruterExample-stripped');
  execFileSync('xcrun', ['strip', '-x', '-S', '-T', '-o', stripped, join(app, 'ScruterExample')]);
  const binary = readFileSync(stripped);
  const bundles = readdirSync(app).filter((f) => /^Scruter.*\.bundle$/.test(f));
  return { bytes: binary.length + bundles.reduce((n, b) => n + size(join(app, b)), 0), code: binary.length, blob: binary };
}

const results = {};
const problems = [];
for (const v of VARIANTS) {
  setModules(v.scruter);
  const r = platform === 'android' ? android() : ios();
  results[v.name] = r;
  for (const [module, marker] of Object.entries(MARKERS)) {
    const has = contains(r.blob, marker);
    if (has !== v.has.includes(module)) problems.push(`${v.name}: the ${module} module is ${has ? 'carried' : 'missing'}`);
  }
}
setModules({ cmp: true });
const kb = (n) => `${(n / 1024).toFixed(0)} KB`;
const lines = [
  `React Native example, ${platform}, release${platform === 'android' ? ' (R8, arm64-v8a)' : ' (arm64, -Osize)'}:`,
  ...VARIANTS.map((v) => `  ${v.name.padEnd(9)} ${kb(results[v.name].bytes)}${platform === 'android' ? ` APK, ${kb(results[v.name].code)} of dex` : ` app binary and Scruter bundles`}`),
  `  Scruter CMP adds ${kb(results.both.bytes - results.analytics.bytes)} to an app with Scruter Analytics` +
    (platform === 'android' ? ` (${kb(results.both.code - results.analytics.code)} of dex)` : ''),
];
console.log(lines.join('\n'));
writeFileSync(join(out, `cmp-size-${platform}.txt`), `${lines.join('\n')}\n`);
if (!existsSync(join(out, `cmp-size-${platform}.txt`))) problems.push('no report');
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
