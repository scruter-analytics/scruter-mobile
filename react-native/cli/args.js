'use strict';

const usage = `Usage: npx scruter symbols upload --app APP_ID [options]

Uploads what makes the crash reports of a release build readable. The token comes from the
environment, never from the command line: SCRUTER_UPLOAD_TOKEN=scr_up_… (App settings › SDK).

  --app APP_ID          the "App identifier" (ATMONA02)
  --platform P          ios, android or all (default: all, what the build left on disk)
  --root DIR            the app's directory (default: the current directory)
  --sourcemap FILE      the final source map, for one platform; repeat with --platform
  --bundle-id ID        the bundle's debug id (default: the one withScruter wrote, else the build's)
  --app-version V       the app's version (default: read from the project)
  --build B             the app's build (default: read from the project)
  --mapping FILE        Android's mapping.txt (default: android/app/build/outputs/mapping/release)
  --dsym PATH           a .dSYM or a folder of them, repeatable (default: what the build left)
  --no-native           source maps only
  --api URL             default https://api.scruter.net (or SCRUTER_API)
  --strict              exit with an error when something could not be sent
  --dry-run             says what would be sent, sends nothing
`;

const VALUES = {
  '--app': 'app',
  '--platform': 'platform',
  '--root': 'root',
  '--sourcemap': 'sourcemap',
  '--bundle-id': 'bundleId',
  '--app-version': 'appVersion',
  '--build': 'build',
  '--mapping': 'mapping',
  '--api': 'api',
};
const FLAGS = { '--no-native': 'noNative', '--strict': 'strict', '--dry-run': 'dryRun', '--help': 'help', '-h': 'help' };

function parseArgs(argv) {
  const args = { dsym: [], platform: 'all', root: '.' };
  const words = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (FLAGS[a]) {
      args[FLAGS[a]] = true;
    } else if (VALUES[a] || a === '--dsym') {
      const value = argv[++i];
      if (value === undefined) return { error: `${a} needs a value` };
      if (a === '--dsym') args.dsym.push(value);
      else args[VALUES[a]] = value;
    } else if (a.startsWith('-')) {
      return { error: `unknown option ${a}` };
    } else {
      words.push(a);
    }
  }
  if (args.help) return args;
  if (words.join(' ') !== 'symbols upload') return { error: 'the command is: scruter symbols upload' };
  if (!args.app) return { error: '--app is required (App identifier, e.g. ATMONA02)' };
  if (!/^[A-Z0-9_-]{1,32}$/.test(args.app)) return { error: `--app ${args.app} is not an app id` };
  if (!['ios', 'android', 'all'].includes(args.platform)) return { error: '--platform is ios, android or all' };
  if (args.sourcemap && args.platform === 'all') return { error: '--sourcemap needs --platform ios or android' };
  return args;
}

module.exports = { parseArgs, usage };
