#!/usr/bin/env node
// What Scruter CMP adds to the example's release build, and M2 (docs/CMP-MOBILE.md): an app carries only the native code
// of the modules its pubspec.yaml takes. Builds the example three times, Scruter Analytics alone, both modules, Scruter
// CMP alone, and checks each build for each module's code. Run scripts/sync-ios-sources.sh first for iOS.
//   node scripts/cmp-size.mjs android|ios
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const platform = process.argv[2];
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const example = join(root, 'example');
const out = join(root, 'build');
mkdirSync(out, { recursive: true });
const run = (cmd, args) => execFileSync(cmd, args, { cwd: example, stdio: 'inherit' });

// What only each module's code holds: a path of its own protocol in the dex, a log line in the Swift binary (Swift keeps
// strings of 15 bytes or less inside the instructions).
const MARKERS =
  platform === 'android'
    ? { analytics: '/m/v1/batch', cmp: '/m/v1/cmp?a=' }
    : { analytics: 'event without a name: ignored', cmp: 'the CMP is off for this app (on: 0)' };
const VARIANTS = [
  { name: 'analytics', block: '', has: ['analytics'] },
  { name: 'both', block: 'scruter:\n  cmp: true\n', has: ['analytics', 'cmp'] },
  { name: 'cmp', block: 'scruter:\n  cmp: true\n  analytics: false\n', has: ['cmp'] },
];
const pubspec = join(example, 'pubspec.yaml');
const manifest = join(example, 'android/app/src/main/AndroidManifest.xml');
const originalPubspec = readFileSync(pubspec, 'utf8');
const originalManifest = readFileSync(manifest, 'utf8');
const base = originalPubspec.replace(/\n# The modules the app takes[^\n]*\nscruter:\n(?: {2}.*\n?)*/, '\n');

function size(path) {
  const s = statSync(path);
  if (!s.isDirectory()) return s.size;
  return readdirSync(path).reduce((n, f) => n + size(join(path, f)), 0);
}

function files(path) {
  const s = statSync(path);
  if (!s.isDirectory()) return [path];
  return readdirSync(path).flatMap((f) => files(join(path, f)));
}

function android() {
  run('flutter', ['build', 'apk', '--release', '--target-platform', 'android-arm64', '--split-per-abi']);
  const apk = join(example, 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk');
  const dex = execFileSync('sh', ['-c', `unzip -p '${apk}' 'classes*.dex'`], { maxBuffer: 1 << 30 });
  return { bytes: statSync(apk).size, code: dex.length, blob: dex };
}

function ios() {
  run('flutter', ['build', 'ios', '--release', '--no-codesign']);
  const framework = join(example, 'build/ios/iphoneos/Runner.app/Frameworks/scruter_flutter.framework');
  const blob = Buffer.concat(files(framework).map((f) => readFileSync(f)));
  // Stripped, as the App Store ships it.
  const stripped = join(out, 'scruter_flutter-stripped');
  execFileSync('xcrun', ['strip', '-x', '-S', '-T', '-o', stripped, join(framework, 'scruter_flutter')]);
  const code = statSync(stripped).size;
  return { bytes: size(framework) - statSync(join(framework, 'scruter_flutter')).size + code, code, blob };
}

const results = {};
const problems = [];
try {
  for (const v of VARIANTS) {
    writeFileSync(pubspec, `${base.trimEnd()}\n${v.block ? `\n${v.block}` : ''}`);
    // The team-phone link is Scruter Analytics' own activity: an app without it does not declare it.
    writeFileSync(manifest, v.has.includes('analytics') ? originalManifest : originalManifest.replace(/\s*<!-- Team phones[\s\S]*?<\/activity>/, ''));
    run('flutter', ['pub', 'get']);
    // Flutter runs pod install again only when its plugins change, not when pubspec.yaml's `scruter` key does.
    if (platform === 'ios') execFileSync('pod', ['install'], { cwd: join(example, 'ios'), stdio: 'inherit' });
    const r = platform === 'android' ? android() : ios();
    results[v.name] = r;
    for (const [module, marker] of Object.entries(MARKERS)) {
      const has = r.blob.includes(Buffer.from(marker, 'latin1'));
      if (has !== v.has.includes(module)) problems.push(`${v.name}: the ${module} module is ${has ? 'carried' : 'missing'}`);
    }
  }
} finally {
  writeFileSync(pubspec, originalPubspec);
  writeFileSync(manifest, originalManifest);
}
const kb = (n) => `${(n / 1024).toFixed(0)} KB`;
const lines = [
  `Flutter example, ${platform}, release${platform === 'android' ? ' (R8, arm64-v8a)' : ' (arm64, -Osize)'}:`,
  ...VARIANTS.map((v) => `  ${v.name.padEnd(9)} ${kb(results[v.name].bytes)}${platform === 'android' ? ` APK, ${kb(results[v.name].code)} of dex` : ' scruter_flutter.framework'}`),
  `  Scruter CMP adds ${kb(results.both.bytes - results.analytics.bytes)} to an app with Scruter Analytics` +
    (platform === 'android' ? ` (${kb(results.both.code - results.analytics.code)} of dex)` : ''),
];
console.log(lines.join('\n'));
writeFileSync(join(out, `cmp-size-${platform}.txt`), `${lines.join('\n')}\n`);
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
