'use strict';
// `withScruter(config)` in metro.config.js: an id of its own for each bundle, needed by apps that ship JavaScript
// without a new build (EAS Update, CodePush): the app version and build no longer tell which bundle crashed.
// The id goes into the bundle as a polyfill, and into the source map through the polyfill's file name, which the CLI
// reads back (docs/MOBILE.md §20). `getPolyfills` is the one serializer hook that Expo's Metro and React Native's share.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const DAY = 24 * 60 * 60 * 1000;

/**
 * One file per platform, written when the config loads: Metro hashes the files of the project at start, so the
 * polyfill has to exist by then, inside the project. Files of older builds go away.
 */
function writePolyfills(projectRoot) {
  const dir = path.join(projectRoot, 'node_modules', '.scruter');
  fs.mkdirSync(dir, { recursive: true });
  for (const name of fs.readdirSync(dir)) {
    const file = path.join(dir, name);
    if (Date.now() - fs.statSync(file).mtimeMs > DAY) fs.rmSync(file, { force: true });
  }
  const files = {};
  for (const platform of ['android', 'ios']) {
    const id = crypto.randomUUID();
    files[platform] = path.join(dir, `scruter-debug-id-${platform}-${id}.js`);
    fs.writeFileSync(files[platform], `global.__SCRUTER_DEBUG_ID__ = ${JSON.stringify(id)};\n`);
  }
  return files;
}

function withScruter(config) {
  const files = writePolyfills(config.projectRoot ?? process.cwd());
  const serializer = config.serializer ?? {};
  const base = serializer.getPolyfills ?? (() => []);
  return {
    ...config,
    serializer: {
      ...serializer,
      getPolyfills: (options) => {
        const own = files[options?.platform];
        return [...base(options), ...(own ? [own] : [])];
      },
    },
  };
}

module.exports = { withScruter };
