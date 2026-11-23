'use strict';
// The Expo config plugin: an Expo app needs no native edit (docs/MOBILE.md §20).
//
//   "plugins": [["@scruter/react-native", { "appId": "ATMONA02" }]]
//
// Works with development builds and EAS Build. Expo Go has no way to load a native module.
const {
  createRunOncePlugin,
  withAppBuildGradle,
  withGradleProperties,
  withInfoPlist,
  withPodfileProperties,
  withXcodeProject,
} = require('@expo/config-plugins');

const pkg = require('../package.json');

const MIN_IOS = '15.0';
const MIN_ANDROID = 24;
const COPY_ENDPOINT = 'https://scruter.net';
const SOURCEMAP_LINE = 'export SOURCEMAP_FILE="$(pwd)/../main.jsbundle.map"';

function scheme(appId) {
  return `scruter-${appId.toLowerCase()}`;
}

/** Info.plist: the team phones' URL scheme, and the copies of Apple's attribution postbacks (§3.13). */
function setInfoPlist(plist, { appId, attribution = true }) {
  const types = Array.isArray(plist.CFBundleURLTypes) ? plist.CFBundleURLTypes : [];
  const name = scheme(appId);
  if (!types.some((t) => (t.CFBundleURLSchemes ?? []).includes(name))) {
    types.push({ CFBundleURLSchemes: [name] });
  }
  plist.CFBundleURLTypes = types;
  if (attribution) {
    // Apple takes one copy address: an app that already gives one to another tool keeps it.
    plist.NSAdvertisingAttributionReportEndpoint ??= COPY_ENDPOINT;
    plist.AdAttributionKit = plist.AdAttributionKit ?? {};
    plist.AdAttributionKit.AttributionCopyEndpoint ??= COPY_ENDPOINT;
  }
  return plist;
}

/** android/app/build.gradle: the placeholder of the SDK's manifest, the same as the Gradle plugin's. */
function setAppGradle(contents, { appId }) {
  const entry = `manifestPlaceholders += [scruterAppId: "${appId.toLowerCase()}"]`;
  if (/scruterAppId/.test(contents)) {
    return contents.replace(/manifestPlaceholders \+= \[scruterAppId: "[^"]*"\]/, entry);
  }
  if (!/defaultConfig\s*\{/.test(contents)) throw new Error('[Scruter] no defaultConfig in android/app/build.gradle');
  return contents.replace(/defaultConfig\s*\{/, (m) => `${m}\n        ${entry}`);
}

function atLeast(current, min) {
  const [a = 0, b = 0] = String(current).split('.').map(Number);
  const [c = 0, d = 0] = min.split('.').map(Number);
  return a > c || (a === c && b >= d);
}

/**
 * Raises a minimum platform, never lowers it. Without a value the template's default holds, which newer Expo SDKs set
 * above ours: only the SDKs before 52 start lower than the SDK's minimum.
 */
function raised(current, min, expoSdk) {
  if (current === undefined) return Number.parseInt(expoSdk ?? '99', 10) < 52 ? min : undefined;
  return atLeast(current, min) ? undefined : min;
}

/** The bundle phase keeps its source map for `npx scruter symbols upload`. */
function setBundlePhase(script) {
  if (script.includes('SOURCEMAP_FILE')) return script;
  // The project file keeps the script as one quoted line.
  return script.replace(/^"/, () => `"${SOURCEMAP_LINE.replace(/"/g, '\\"')}\\n`);
}

function withScruter(config, props = {}) {
  const appId = props.appId;
  if (!appId || !/^[A-Z0-9_-]{1,32}$/.test(appId)) {
    throw new Error('[Scruter] the plugin needs { "appId": "ATMONA02" }, the App identifier of App settings › SDK');
  }
  const options = { appId, attribution: props.attribution !== false };
  let out = withInfoPlist(config, (c) => {
    c.modResults = setInfoPlist(c.modResults, options);
    return c;
  });
  out = withAppBuildGradle(out, (c) => {
    c.modResults.contents = setAppGradle(c.modResults.contents, options);
    return c;
  });
  out = withGradleProperties(out, (c) => {
    const entry = c.modResults.find((p) => p.type === 'property' && p.key === 'android.minSdkVersion');
    const value = raised(entry?.value, String(MIN_ANDROID), config.sdkVersion);
    if (value && entry) entry.value = value;
    else if (value) c.modResults.push({ type: 'property', key: 'android.minSdkVersion', value });
    return c;
  });
  out = withPodfileProperties(out, (c) => {
    const value = raised(c.modResults['ios.deploymentTarget'], MIN_IOS, config.sdkVersion);
    if (value) c.modResults['ios.deploymentTarget'] = value;
    return c;
  });
  out = withXcodeProject(out, (c) => {
    const phases = c.modResults.hash.project.objects.PBXShellScriptBuildPhase ?? {};
    for (const phase of Object.values(phases)) {
      if (typeof phase === 'object' && /react-native-xcode\.sh/.test(phase.shellScript ?? '')) {
        phase.shellScript = setBundlePhase(phase.shellScript);
      }
    }
    return c;
  });
  return out;
}

module.exports = createRunOncePlugin(withScruter, pkg.name, pkg.version);
module.exports.setAppGradle = setAppGradle;
module.exports.setBundlePhase = setBundlePhase;
module.exports.setInfoPlist = setInfoPlist;
module.exports.raised = raised;
