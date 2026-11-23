const fs = require('fs');
const os = require('os');
const path = require('path');
const { modulesOf, raised, setAppGradle, setBundlePhase, setInfoPlist, setTrackingDescription } = require('../plugin');
const plugin = require('../app.plugin.js');

const GRADLE = `android {
    namespace 'fr.atelier'
    defaultConfig {
        applicationId 'fr.atelier'
    }
}`;

describe('setInfoPlist', () => {
  it('adds the scheme and the attribution endpoints, once', () => {
    const p = setInfoPlist(setInfoPlist({}, { appId: 'ATMONA02' }), { appId: 'ATMONA02' });
    expect(p.CFBundleURLTypes).toEqual([{ CFBundleURLSchemes: ['scruter-atmona02'] }]);
    expect(p.NSAdvertisingAttributionReportEndpoint).toBe('https://scruter.net');
    expect(p.AdAttributionKit.AttributionCopyEndpoint).toBe('https://scruter.net');
  });

  it('keeps the app\'s schemes and another tool\'s copy address', () => {
    const p = setInfoPlist(
      {
        CFBundleURLTypes: [{ CFBundleURLSchemes: ['atelier'] }],
        NSAdvertisingAttributionReportEndpoint: 'https://other.example',
      },
      { appId: 'ATMONA02' },
    );
    expect(p.CFBundleURLTypes).toHaveLength(2);
    expect(p.NSAdvertisingAttributionReportEndpoint).toBe('https://other.example');
  });

  it('leaves attribution out when asked', () => {
    const p = setInfoPlist({}, { appId: 'ATMONA02', attribution: false });
    expect(p.NSAdvertisingAttributionReportEndpoint).toBeUndefined();
  });
});

describe('setAppGradle', () => {
  it('sets the placeholder in defaultConfig, once', () => {
    const once = setAppGradle(GRADLE, { appId: 'ATMONA02' });
    expect(once).toContain('manifestPlaceholders += [scruterAppId: "atmona02"]');
    expect(setAppGradle(once, { appId: 'ATMONA02' })).toBe(once);
    expect(setAppGradle(once, { appId: 'ATMONA03' })).toContain('"atmona03"');
  });

  it('says so when it cannot', () => {
    expect(() => setAppGradle('nothing', { appId: 'A' })).toThrow('defaultConfig');
  });
});

describe('setBundlePhase', () => {
  it('keeps the source map, once', () => {
    const script = '"if [[ -f x ]]; then\\n bash react-native-xcode.sh\\nfi\\n"';
    const out = setBundlePhase(script);
    expect(out.startsWith('"export SOURCEMAP_FILE=\\"$(pwd)/../main.jsbundle.map\\"\\n')).toBe(true);
    expect(setBundlePhase(out)).toBe(out);
  });
});

describe('raised', () => {
  it('raises a lower minimum and never lowers one', () => {
    expect(raised('13.4', '15.0', '58.0.0')).toBe('15.0');
    expect(raised('16.4', '15.0', '58.0.0')).toBeUndefined();
    expect(raised('23', '24')).toBe('24');
    expect(raised('26', '24')).toBeUndefined();
  });

  it('leaves a recent template\'s default alone', () => {
    expect(raised(undefined, '15.0', '58.0.0')).toBeUndefined();
    expect(raised(undefined, '15.0', '50.0.0')).toBe('15.0');
    expect(raised(undefined, '15.0', undefined)).toBeUndefined();
  });
});

describe('the plugin', () => {
  it('refuses a missing app id', () => {
    expect(() => plugin({ name: 'a', slug: 'a' }, {})).toThrow('appId');
  });

  it('registers its modifications', () => {
    const c = plugin({ name: 'a', slug: 'a' }, { appId: 'ATMONA02' });
    expect(Object.keys(c.mods.ios).sort()).toEqual(['infoPlist', 'podfileProperties', 'xcodeproj']);
    expect(Object.keys(c.mods.android).sort()).toEqual(['appBuildGradle', 'gradleProperties']);
  });
});

/** An Expo project whose package.json has this "scruter" key. */
function project(scruter) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'scruter-plugin-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: 'app', ...(scruter ? { scruter } : {}) }));
  return { name: 'a', slug: 'a', _internal: { projectRoot: dir } };
}

describe('Scruter CMP in the plugin', () => {
  it('reads the modules as the podspec and Gradle do', () => {
    expect(modulesOf(project()._internal.projectRoot)).toEqual({ analytics: true, cmp: false });
    expect(modulesOf(project({ cmp: true })._internal.projectRoot)).toEqual({ analytics: true, cmp: true });
    expect(modulesOf(project({ cmp: true, analytics: false })._internal.projectRoot)).toEqual({ analytics: false, cmp: true });
    expect(modulesOf('/nowhere')).toEqual({ analytics: true, cmp: false });
  });

  it('needs nothing for the CMP alone: no app id, no Analytics change', () => {
    const c = plugin(project({ cmp: true, analytics: false }), {});
    expect(Object.keys(c.mods.ios).sort()).toEqual(['podfileProperties']);
    expect(Object.keys(c.mods.android).sort()).toEqual(['gradleProperties']);
  });

  it('sets the tracking prompt\'s text when the app asks it', () => {
    const c = plugin(project({ cmp: true, analytics: false }), { trackingDescription: 'To show you ads about our bowls.' });
    expect(Object.keys(c.mods.ios).sort()).toEqual(['infoPlist', 'podfileProperties']);
    expect(setTrackingDescription({}, 'To show you ads.')).toEqual({ NSUserTrackingUsageDescription: 'To show you ads.' });
    expect(setTrackingDescription({ NSUserTrackingUsageDescription: 'Kept' }, undefined)).toEqual({ NSUserTrackingUsageDescription: 'Kept' });
  });

  it('keeps the Analytics changes for an app with both', () => {
    const c = plugin(project({ cmp: true }), { appId: 'ATMONA02', trackingDescription: 'Ads.' });
    expect(Object.keys(c.mods.ios).sort()).toEqual(['infoPlist', 'podfileProperties', 'xcodeproj']);
    expect(() => plugin(project({ cmp: true }), {})).toThrow('appId');
  });

  it('refuses a tracking text without the CMP, or an empty one', () => {
    expect(() => plugin(project(), { appId: 'ATMONA02', trackingDescription: 'Ads.' })).toThrow('cmp');
    expect(() => plugin(project({ cmp: true }), { appId: 'ATMONA02', trackingDescription: ' ' })).toThrow('sentence');
  });
});
