const pkg = require('../package.json');

describe('the package an app imports', () => {
  it('points every tool at compiled JavaScript', () => {
    // An app's Jest does not transform node_modules: raw TypeScript here fails at the first import of the package.
    const entries = [pkg.main, ...Object.values(pkg.exports['.'])].filter((p) => !p.endsWith('.d.ts'));
    expect(entries.length).toBeGreaterThan(0);
    for (const entry of entries) expect(entry).toMatch(/lib\/.*\.js$/);
    expect(pkg['react-native']).toBeUndefined();
  });
});
