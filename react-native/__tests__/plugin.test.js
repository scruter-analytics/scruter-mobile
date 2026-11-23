const { raised, setAppGradle, setBundlePhase, setInfoPlist } = require('../plugin');
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
