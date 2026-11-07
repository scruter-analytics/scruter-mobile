'use strict';
// What the project on disk says: the files a build left, the app's version and build.
const fs = require('node:fs');
const path = require('node:path');

function read(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
}

function walk(dir, match, depth = 6, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (match(e, p)) out.push(p);
    else if (e.isDirectory() && depth > 0 && e.name !== 'node_modules') walk(p, match, depth - 1, out);
  }
  return out;
}

const newest = (files) =>
  files.map((f) => [fs.statSync(f).mtimeMs, f]).sort((a, b) => b[0] - a[0])[0]?.[1];

/** The final source map of a platform: the one Hermes's compiler map was composed into, or JavaScriptCore's. */
function findSourceMap(root, platform) {
  if (platform === 'android') {
    const dir = path.join(root, 'android/app/build/generated/sourcemaps/react');
    const all = walk(dir, (e) => e.isFile() && e.name.endsWith('.bundle.map'));
    return newest(all.filter((f) => !/[/\\]debug[/\\]/i.test(f)));
  }
  const candidates = [
    process.env.SOURCEMAP_FILE,
    path.join(root, 'main.jsbundle.map'),
    path.join(root, 'ios/main.jsbundle.map'),
    path.join(root, 'ios/build/main.jsbundle.map'),
  ].filter(Boolean);
  return newest(candidates.filter((f) => fs.existsSync(f)));
}

function findMapping(root) {
  const dir = path.join(root, 'android/app/build/outputs/mapping');
  return newest(walk(dir, (e) => e.isFile() && e.name === 'mapping.txt', 3).filter((f) => !/[/\\]debug[/\\]/i.test(f)));
}

function findDsyms(root) {
  const dirs = [process.env.DWARF_DSYM_FOLDER_PATH, path.join(root, 'ios/build')].filter(Boolean);
  return dirs.flatMap((d) => walk(d, (e) => e.isDirectory() && e.name.endsWith('.dSYM'), 8));
}

/** The iOS SDK's script, which this package carries (scripts/sync-ios.mjs). */
function findUploadSymbols() {
  const script = path.join(__dirname, '../ios/sdk/upload-symbols');
  return fs.existsSync(script) ? script : undefined;
}

const expoConfig = (root) => {
  const json = read(path.join(root, 'app.json'));
  if (!json) return undefined;
  try {
    return JSON.parse(json).expo;
  } catch {
    return undefined;
  }
};

function androidVersion(root) {
  const gradle = read(path.join(root, 'android/app/build.gradle')) ?? read(path.join(root, 'android/app/build.gradle.kts'));
  const expo = expoConfig(root);
  return {
    version: gradle?.match(/versionName\s*=?\s*["']([^"']+)["']/)?.[1] ?? expo?.version,
    build: gradle?.match(/versionCode\s*=?\s*(\d+)/)?.[1] ?? expo?.android?.versionCode?.toString(),
  };
}

function iosVersion(root) {
  const ios = path.join(root, 'ios');
  const projects = walk(ios, (e) => e.isDirectory() && e.name.endsWith('.xcodeproj'), 1).filter((p) => !/[/\\]Pods[/\\]/.test(p));
  const pbx = projects.map((p) => read(path.join(p, 'project.pbxproj'))).find(Boolean);
  const expo = expoConfig(root);
  const plain = (v) => (v && !v.includes('$') ? v : undefined);
  const plists = walk(ios, (e) => e.isFile() && e.name === 'Info.plist', 2).filter((f) => !/Tests|Pods/.test(f));
  const plist = plists.map(read).find(Boolean);
  const key = (name) => plain(plist?.match(new RegExp(`<key>${name}</key>\\s*<string>([^<]+)</string>`))?.[1]);
  return {
    version:
      key('CFBundleShortVersionString') ?? pbx?.match(/MARKETING_VERSION = ([^;]+);/)?.[1]?.replace(/"/g, '') ?? expo?.version,
    build:
      key('CFBundleVersion') ??
      pbx?.match(/CURRENT_PROJECT_VERSION = ([^;]+);/)?.[1]?.replace(/"/g, '') ??
      expo?.ios?.buildNumber,
  };
}

/** Whether the app runs Hermes: its map must then be the composed one. */
function usesHermes(root, platform) {
  if (platform === 'android') {
    const props = read(path.join(root, 'android/gradle.properties')) ?? '';
    return !/^\s*hermesEnabled\s*=\s*false/m.test(props);
  }
  const podfile = read(path.join(root, 'ios/Podfile.lock')) ?? '';
  return /hermes-engine/.test(podfile) || !podfile;
}

module.exports = { androidVersion, findDsyms, findMapping, findSourceMap, findUploadSymbols, iosVersion, usesHermes };
