#!/usr/bin/env node
// `VERSION` is the one place that sets the version of the four SDKs (docs/RUNBOOK.md, "Publishing the mobile SDKs").
// Every manifest, the versions the SDKs send in batches and the install lines of the guides are written from it:
//
//   node scripts/version.mjs check        every target against VERSION; the publish workflow runs it first
//   node scripts/version.mjs set 1.1.0    writes VERSION and every target (not what announces a published version)
//   node scripts/version.mjs latest       after the publication: LATEST_SDK and the public docs, in the monorepo
//
// `sdk/` is mirrored to the root of the public repository, which has no backend: outside the monorepo, `latest` stops
// and `check` skips those files.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION_RE = /^\d+\.\d+\.\d+$/;
const V = '(\\d+\\.\\d+\\.\\d+)';

/** Files of the SDKs: `pattern` holds one group, the version; `count` is how many times it must match. */
export const SDK_TARGETS = [
  { file: 'Scruter.podspec', pattern: `s\\.version\\s*=\\s*'${V}'` },
  { file: 'ios/Sources/ScruterAnalytics/Core/Environment.swift', pattern: `scruterSDKVersion = "${V}"` },
  { file: 'ios/upload-symbols', pattern: `scruter-upload-symbols/${V}`, count: 2 },
  { file: 'ios/README.md', pattern: `scruter-mobile", from: "${V}"` },
  { file: 'ios/README.md', pattern: `:tag => '${V}'` },

  { file: 'android/scruter-android/build.gradle.kts', pattern: `val sdkVersion = "${V}"` },
  { file: 'android/scruter-symbols-gradle-plugin/build.gradle.kts', pattern: `^version = "${V}"` },
  { file: 'android/README.md', pattern: `id\\("net\\.scruter\\.symbols"\\) version "${V}"` },
  { file: 'android/README.md', pattern: `net\\.scruter:scruter-android:${V}` },

  { file: 'flutter/pubspec.yaml', pattern: `^version: ${V}$` },
  { file: 'flutter/lib/src/scruter.dart', pattern: `const scruterVersion = '${V}'` },
  { file: 'flutter/ios/scruter_flutter.podspec', pattern: `s\\.version\\s*=\\s*'${V}'` },
  { file: 'flutter/ios/scruter_flutter/Package.swift', pattern: `scruter-mobile", from: "${V}"` },
  { file: 'flutter/android/build.gradle', pattern: `^version '${V}'` },
  { file: 'flutter/android/build.gradle', pattern: `net\\.scruter:scruter-android:${V}` },
  { file: 'flutter/test/support.dart', pattern: `'sdk': 'flutter/${V}'` },
  { file: 'flutter/scripts/device-check.mjs', pattern: `flutter/${V}`, count: 2 },

  { file: 'react-native/package.json', pattern: `"version": "${V}"` },
  { file: 'react-native/package-lock.json', pattern: `"name": "@scruter/react-native",\\s+"version": "${V}"`, count: 2 },
  { file: 'react-native/src/scruter.ts', pattern: `export const VERSION = '${V}'` },
  { file: 'react-native/android/build.gradle', pattern: `net\\.scruter:scruter-android:${V}` },
  { file: 'react-native/android/src/main/java/net/scruter/reactnative/ScruterModule.java', pattern: `version == null \\? "${V}"` },
  { file: 'react-native/ios/ScruterHost.swift', pattern: `as\\? String \\?\\? "${V}"` },
  { file: 'react-native/cli/client.js', pattern: `scruter-cli/${V}` },
  { file: 'react-native/__tests__/errors.test.ts', pattern: `react_native/${V}` },
  { file: 'react-native/__tests__/scruter.test.ts', pattern: `version: '${V}'` },
];

/** Files of the monorepo that announce a published version, relative to `sdk/`: never ahead of VERSION. */
export const PUBLISHED_TARGETS = [
  { file: '../backend/crates/core/src/mobile.rs', pattern: `\\("(?:ios|android|react_native|flutter)", "${V}"\\)`, count: 4 },
  ...['fr', 'en', 'de'].flatMap((locale) => [
    { file: `../frontend/content/docs/${locale}/mobile.mdx`, pattern: `id\\("net\\.scruter\\.symbols"\\) version "${V}"` },
    { file: `../frontend/content/docs/${locale}/mobile.mdx`, pattern: `net\\.scruter:scruter-android:${V}` },
  ]),
];

/** The changelogs a version needs before it publishes (pub.dev shows Flutter's, the GitHub release reads the root's). */
const CHANGELOGS = ['CHANGELOG.md', 'flutter/CHANGELOG.md'];

function regex(target) {
  return new RegExp(target.pattern, 'gm');
}

function compare(a, b) {
  const [x, y] = [a, b].map((v) => v.split('.').map(Number));
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
}

/** The versions a target holds; an error names a target that no longer matches, so a rename cannot go unnoticed. */
export function read(root, target) {
  const text = readFileSync(join(root, target.file), 'utf8');
  const found = [...text.matchAll(regex(target))].map((m) => m[1]);
  const count = target.count ?? 1;
  if (found.length !== count) {
    throw new Error(`${target.file}: /${target.pattern}/ matches ${found.length} time(s), expected ${count}`);
  }
  return found;
}

function write(root, target, version) {
  read(root, target);
  const path = join(root, target.file);
  const text = readFileSync(path, 'utf8').replace(regex(target), (match, old) => match.replace(old, version));
  writeFileSync(path, text);
}

/** `react-native/` may be absent on a branch, the backend in the public repository: the caller says what that means. */
function present(root, targets) {
  return targets.filter((t) => existsSync(join(root, t.file)));
}

function changelogHas(root, file, version) {
  const path = join(root, file);
  if (!existsSync(path)) return false;
  return new RegExp(`^## ${version.replaceAll('.', '\\.')}(\\s|$)`, 'm').test(readFileSync(path, 'utf8'));
}

export function readVersion(root) {
  const version = readFileSync(join(root, 'VERSION'), 'utf8').trim();
  if (!VERSION_RE.test(version)) throw new Error(`VERSION: ${JSON.stringify(version)} is not x.y.z`);
  return version;
}

/** Everything that disagrees with VERSION, as sentences. */
export function problems(root) {
  const version = readVersion(root);
  const out = [];
  for (const target of present(root, SDK_TARGETS)) {
    for (const found of read(root, target)) {
      if (found !== version) out.push(`${target.file}: ${found}, VERSION says ${version}`);
    }
  }
  for (const target of present(root, PUBLISHED_TARGETS)) {
    for (const found of read(root, target)) {
      if (compare(found, version) > 0) out.push(`${target.file}: ${found} is ahead of VERSION (${version})`);
    }
  }
  for (const file of CHANGELOGS) {
    if (!changelogHas(root, file, version)) out.push(`${file}: no "## ${version}" section`);
  }
  return out;
}

export function setVersion(root, version) {
  if (!VERSION_RE.test(version)) throw new Error(`${JSON.stringify(version)} is not x.y.z`);
  writeFileSync(join(root, 'VERSION'), `${version}\n`);
  for (const target of present(root, SDK_TARGETS)) write(root, target, version);
}

export function markPublished(root) {
  const version = readVersion(root);
  const targets = present(root, PUBLISHED_TARGETS);
  if (targets.length !== PUBLISHED_TARGETS.length) throw new Error('`latest` runs in the monorepo, from sdk/');
  for (const target of targets) write(root, target, version);
  return version;
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const [command, argument] = process.argv.slice(2);
  if (command === 'check') {
    const found = problems(root);
    for (const line of found) console.error(line);
    if (found.length > 0) process.exit(1);
    const skipped = [...SDK_TARGETS, ...PUBLISHED_TARGETS].filter((t) => !existsSync(join(root, t.file)));
    for (const file of new Set(skipped.map((t) => t.file))) console.log(`not in this tree: ${file}`);
    console.log(`every target says ${readVersion(root)}`);
  } else if (command === 'set' && argument) {
    setVersion(root, argument);
    console.log(`VERSION and every target now say ${argument}: add a "## ${argument}" section to the changelogs`);
  } else if (command === 'latest') {
    console.log(`LATEST_SDK and the public docs now say ${markPublished(root)}`);
  } else {
    console.error('usage: version.mjs check | set <x.y.z> | latest');
    process.exit(2);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
