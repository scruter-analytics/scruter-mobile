// Checks the CMP kit (README.md): every golden body against its JSON Schema, and the bodies the schemas must refuse
// (a site's beacon, an unknown platform). Node ≥ 20, no dependency: `node check.mjs`.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../validate.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const read = (p) => JSON.parse(readFileSync(join(here, p), 'utf8'));
const schemaOf = (file) =>
  file.startsWith('config') ? 'cmp-config' : file.startsWith('hit') ? 'cmp-hit' : file.startsWith('consent') ? 'cmp-consent' : 'cmp-sdks';

let failed = 0;
const report = (name, errors, expectValid = true) => {
  const ok = expectValid ? errors.length === 0 : errors.length > 0;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok || !expectValid ? '' : `\n  ${errors.slice(0, 5).join('\n  ')}`}`);
};

for (const file of readdirSync(join(here, 'bodies')).sort()) {
  report(`bodies/${file}`, validate(schemaOf(file), read(`bodies/${file}`)));
}

// What the schemas refuse.
const hit = read('bodies/hit.json');
const consent = read('bodies/consent.json');
for (const [name, schema, body] of [
  ['a site\'s hit (page URL, held resources)', 'cmp-hit', { ...hit, u: 'https://atelier-mona.fr/', k: 3 }],
  ['an unknown platform', 'cmp-hit', { ...hit, p: 'macos' }],
  ['a hit without the app id', 'cmp-hit', Object.fromEntries(Object.entries(hit).filter(([k]) => k !== 'ap'))],
  ['the floating button (none in an app)', 'cmp-consent', { ...consent, o: 'floating_button' }],
  ['a TC string without its GVL version', 'cmp-consent', { ...consent, tc: 'CQAAAAAQAAAA' }],
  ['a configuration with a page\'s blocking rules', 'cmp-config', (() => { const c = read('bodies/config.json'); c.config.block = {}; return c; })()],
  ['a TCF configuration without its translations', 'cmp-config', (() => { const c = read('bodies/config-tcf.json'); delete c.config.tcf.translations_url; return c; })()],
  ['an answer `on: 0` with a configuration', 'cmp-config', { ...read('bodies/config-off.json'), config: {} }],
]) {
  report(`refused: ${name}`, validate(schema, body), false);
}

// The catalogue the backend serves, when this kit sits in the Scruter monorepo.
const catalogue = join(here, '../../../backend/crates/cmp/data/app_sdks.json');
if (existsSync(catalogue)) {
  const c = JSON.parse(readFileSync(catalogue, 'utf8'));
  const wire = { v: c.version, sdks: c.sdks.map((s) => ({ k: s.key, ...(s.ios.length ? { ios: s.ios } : {}), ...(s.android.length ? { android: s.android } : {}) })) };
  report('the SDK catalogue (backend/crates/cmp/data/app_sdks.json)', validate('cmp-sdk-catalogue', wire));
}

for (const v of ['stored-value', 'reask', 'consent-mode']) read(`vectors/${v}.json`);

// The TCF vectors: each case's keys agree with its string and model, the files they name exist.
const tcf = read('tcf-vectors.json');
const tcfProblems = [];
for (const c of tcf.cases) {
  if (c.vendor_list) read(c.vendor_list);
  const k = c.keys;
  if (k.IABTCF_TCString !== c.tc) tcfProblems.push(`${c.name}: TC string`);
  if (k.IABTCF_CmpSdkID !== c.settings.cmp_id || k.IABTCF_gdprApplies !== 1) tcfProblems.push(`${c.name}: header keys`);
  if (k.IABTCF_PurposeConsents.length !== 11 || k.IABTCF_SpecialFeaturesOptIns.length !== 2) tcfProblems.push(`${c.name}: field lengths`);
  for (const id of c.model.vendorConsents) if (k.IABTCF_VendorConsents[id - 1] !== '1') tcfProblems.push(`${c.name}: vendor ${id}`);
  // Google's Additional Consent: the key exactly for a site with providers, the string of the case.
  const ac = (c.settings.ac_providers || []).length > 0;
  if (ac !== ('IABTCF_AddtlConsent' in k) || (ac && k.IABTCF_AddtlConsent !== c.ac)) tcfProblems.push(`${c.name}: Additional Consent key`);
  if (ac && !/^2~[0-9.]*~dv\.[0-9.]*$/.test(c.ac)) tcfProblems.push(`${c.name}: Additional Consent string`);
}
for (const f of ['tcf/vendors-186.json', 'tcf/186-fr.json', 'tcf/186-de.json']) read(f);
report(`TCF vectors: ${tcf.cases.length} cases, ${tcf.reask.length} re-asks`, tcfProblems);

// The words: the same keys in every language, every value a non-empty string, the placeholders kept.
const langs = readdirSync(join(here, 'words')).filter((f) => f.endsWith('.json')).sort();
const fr = read('words/fr.json');
const problems = [];
for (const f of langs) {
  const w = read(`words/${f}`);
  const keys = Object.keys(w).sort().join(',');
  if (keys !== Object.keys(fr).sort().join(',')) problems.push(`${f}: keys differ from fr.json`);
  for (const [k, v] of Object.entries(w)) {
    if (typeof v !== 'string' || v.length === 0) problems.push(`${f}: ${k} empty`);
    for (const p of (fr[k].match(/\{[a-z]\}/g) || [])) if (!v.includes(p)) problems.push(`${f}: ${k} lacks ${p}`);
  }
}
report(`words: ${langs.length} languages`, problems);
console.log(failed ? `\n${failed} failed` : '\nall passed');
process.exit(failed ? 1 : 0);
