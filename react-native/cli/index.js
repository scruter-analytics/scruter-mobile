#!/usr/bin/env node
'use strict';
// `npx scruter symbols upload`: everything that makes the crash reports of a release readable, in one command
// (docs/MOBILE.md §4.3): the JavaScript source maps, Hermes and JavaScriptCore; the R8 mapping; the dSYMs, handed to
// the iOS SDK's `upload-symbols`. A build never fails for symbols unless `--strict` says so.
const { parseArgs, usage } = require('./args');
const { upload } = require('./upload');

async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) {
    process.stdout.write(usage);
    return 0;
  }
  if (args.error) {
    process.stderr.write(`scruter: ${args.error}\n\n${usage}`);
    return 2;
  }
  return upload(args, process.env, (line) => process.stdout.write(`${line}\n`));
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (e) => {
    process.stderr.write(`scruter: ${e.message}\n`);
    process.exitCode = 1;
  },
);
