'use strict';
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { Client } = require('./client');
const project = require('./project');

const ID_IN_SOURCES = /scruter-debug-id-[a-z]+-([0-9a-f-]{36})\.js/;
const SAFE_ID = /[^A-Za-z0-9._:-]/g;

/** The id the app reports without `withScruter`: the same as the native modules' `defaultBundleId`. */
function defaultBundleId(platform, version, build) {
  return `rn-${platform}-${version}-${build}`.replace(SAFE_ID, '_').slice(0, 100);
}

/** The debug id of a source map: its own, the id `withScruter` wrote into the bundle, or none. */
function debugIdOf(map) {
  if (typeof map.debugId === 'string' && map.debugId) return map.debugId;
  if (typeof map.debug_id === 'string' && map.debug_id) return map.debug_id;
  for (const s of map.sources ?? []) {
    const m = typeof s === 'string' ? ID_IN_SOURCES.exec(s) : null;
    if (m) return m[1];
  }
  return undefined;
}

/** What is sent: the map with its id, without the app's source code. */
function prepare(map, id) {
  const { sourcesContent: _dropped, ...rest } = map;
  return zlib.gzipSync(Buffer.from(JSON.stringify({ ...rest, debugId: id })));
}

function parseMap(file) {
  const map = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (map.version !== 3 || typeof map.mappings !== 'string') throw new Error(`${file} is not a source map`);
  return map;
}

function mappingId(file) {
  const head = fs.readFileSync(file, 'utf8').split('\n', 40);
  for (const line of head) {
    if (!line.startsWith('#')) break;
    const m = /^# pg_map_id:\s*(\S+)/.exec(line);
    if (m) return m[1];
  }
  return undefined;
}

async function sendOne(client, file, bytes, say, dryRun) {
  if (dryRun) {
    say(`${file.file_name}: ${file.kind} ${file.debug_id}, ${bytes.length} bytes (dry run: not sent)`);
    return;
  }
  const missing = await client.missing([{ kind: file.kind, debug_id: file.debug_id }]);
  if (missing.length === 0) {
    say(`${file.file_name}: already on Scruter (${file.debug_id})`);
    return;
  }
  const sent = await client.send(file, bytes);
  say(`${file.file_name}: ${sent ? 'uploaded' : 'already on Scruter'} (${file.debug_id})`);
}

async function sourceMap(client, args, platform, say) {
  const root = args.root;
  const file = args.sourcemap ?? project.findSourceMap(root, platform);
  if (!file) {
    throw new Error(
      platform === 'ios'
        ? 'no iOS source map: set SOURCEMAP_FILE in the "Bundle React Native code and images" phase, or give --sourcemap'
        : 'no Android source map: build a release first (bundle or assemble), or give --sourcemap',
    );
  }
  const map = parseMap(file);
  if (project.usesHermes(root, platform) && !map.x_hermes_function_offsets) {
    say(`warning: ${path.basename(file)} is not composed with Hermes's map: stacks will not resolve on a Hermes build`);
  }
  const facts = platform === 'ios' ? project.iosVersion(root) : project.androidVersion(root);
  const version = args.appVersion ?? facts.version;
  const build = args.build ?? facts.build;
  let id = args.bundleId ?? debugIdOf(map);
  if (!id) {
    if (!version || !build) throw new Error(`the ${platform} version or build is unknown: give --app-version and --build`);
    id = defaultBundleId(platform, version, build);
  }
  const bytes = prepare(map, id);
  await sendOne(
    client,
    {
      platform: 'react_native',
      kind: 'source_map',
      debug_id: id,
      app_version: version ?? '',
      build: build ?? '',
      file_name: `${path.basename(file)}.gz`,
    },
    bytes,
    say,
    args.dryRun,
  );
}

async function r8Mapping(client, args, say) {
  const file = args.mapping ?? project.findMapping(args.root);
  if (!file) {
    say('no R8 mapping found: nothing to upload for the native Android layer');
    return;
  }
  const id = mappingId(file);
  if (!id) throw new Error(`${file} has no pg_map_id: it is not an R8 mapping`);
  const facts = project.androidVersion(args.root);
  await sendOne(
    client,
    {
      platform: 'android',
      kind: 'r8_mapping',
      debug_id: id,
      app_version: args.appVersion ?? facts.version ?? '',
      build: args.build ?? facts.build ?? '',
      file_name: 'mapping.txt.gz',
    },
    zlib.gzipSync(fs.readFileSync(file)),
    say,
    args.dryRun,
  );
}

/** dSYMs: the iOS SDK's own script does the work (UUIDs need Xcode's tools): a hand-off, on a Mac. */
function dsyms(args, env, say) {
  const paths = args.dsym.length ? args.dsym : project.findDsyms(args.root);
  if (paths.length === 0) {
    say('no dSYM found: nothing to upload for the native iOS layer (--dsym, or the Xcode build phase of the guide)');
    return;
  }
  if (process.platform !== 'darwin') {
    say('dSYMs need Xcode\'s tools: run this on a Mac, or use the Xcode build phase of the guide');
    return;
  }
  const script = project.findUploadSymbols();
  if (!script) throw new Error('upload-symbols not found in the package: reinstall @scruter/react-native');
  const argv = ['--app', args.app, '--force', ...(args.strict ? ['--strict'] : []), ...paths];
  if (args.dryRun) {
    say(`would run: upload-symbols ${argv.join(' ')}`);
    return;
  }
  const run = spawnSync(script, argv, { stdio: 'inherit', env: { ...env, SCRUTER_API: args.api } });
  if (run.status !== 0) throw new Error('upload-symbols failed');
}

const has = (args, platform) => args.platform === 'all' || args.platform === platform;

/** Runs the command; the exit code. A failure stops one step, not the others. */
async function upload(args, env, say, fetchImpl) {
  const resolved = { ...args, api: args.api ?? env.SCRUTER_API ?? 'https://api.scruter.net', root: path.resolve(args.root) };
  const token = env.SCRUTER_UPLOAD_TOKEN ?? '';
  if (!resolved.dryRun && !/^scr_up_/.test(token)) {
    say(
      token
        ? 'warning: SCRUTER_UPLOAD_TOKEN is not an upload token (scr_up_…): nothing uploaded'
        : 'warning: SCRUTER_UPLOAD_TOKEN is not set: nothing uploaded (App settings › SDK › Create a token)',
    );
    return resolved.strict ? 1 : 0;
  }
  const client = new Client({ api: resolved.api, token, app: resolved.app, fetchImpl });
  const failures = [];
  const step = async (run) => {
    try {
      await run();
    } catch (e) {
      failures.push(e.message);
      say(`warning: ${e.message}`);
    }
  };
  // `all`: what the build left on disk. A platform named outright must have its map.
  for (const platform of ['android', 'ios']) {
    if (!has(resolved, platform)) continue;
    const present = resolved.platform !== 'all' || project.findSourceMap(resolved.root, platform);
    if (!present) continue;
    await step(() => sourceMap(client, resolved, platform, say));
  }
  if (!resolved.noNative) {
    if (has(resolved, 'android')) await step(() => r8Mapping(client, resolved, say));
    if (has(resolved, 'ios')) await step(async () => dsyms(resolved, env, say));
  }
  return failures.length && resolved.strict ? 1 : 0;
}

module.exports = { debugIdOf, defaultBundleId, mappingId, prepare, upload };
