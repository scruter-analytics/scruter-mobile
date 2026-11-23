// Writes tcf-vectors.json from the site script's own TCF code (cmp/src/tcf/model.ts and tcstring.ts in the Scruter
// monorepo), so that the web and the apps encode alike (docs/CMP-MOBILE.md §6): each case's TC model, TC string, Google's
// Additional Consent string for a site with Google's other ad tech providers, and the in-app keys `IABTCF_*` of the
// IAB's CMP API v2.2 (« In-App Details ») with `IABTCF_AddtlConsent`, and the re-ask of a stored string (docs/CMP.md
// §4.4 rule 5). Node ≥ 20; needs the monorepo's cmp/ with its dependencies installed (esbuild).
//   node tcf-vectors.mjs           writes the file
//   node tcf-vectors.mjs --check   fails when the file is out of date
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cmp = join(here, '../../../cmp');
if (!existsSync(join(cmp, 'node_modules/esbuild'))) {
  console.error('tcf-vectors.mjs runs in the Scruter monorepo, after `pnpm install` in cmp/');
  process.exit(2);
}
const { build } = await import(pathToFileURL(join(cmp, 'node_modules/esbuild/lib/main.js')).href);
const out = await build({
  stdin: {
    contents: 'export * from "./src/tcf/model"; export { encode, decode, today } from "./src/tcf/tcstring"; export { cover, featureStack } from "./src/tcf/stacks";',
    resolveDir: cmp,
    loader: 'ts',
  },
  bundle: true,
  format: 'esm',
  write: false,
  platform: 'neutral',
});
const dir = mkdtempSync(join(tmpdir(), 'scruter-tcf-'));
const mod = join(dir, 'tcf.mjs');
writeFileSync(mod, out.outputFiles[0].text);
const T = await import(pathToFileURL(mod).href);
rmSync(dir, { recursive: true, force: true });

const read = (p) => JSON.parse(readFileSync(join(here, p), 'utf8'));
const list = read('tcf/vendors-186.json');
// 2026-11-22 15:30 UTC: the strings carry the day only.
const NOW = Date.UTC(2026, 10, 22, 15, 30);
const PURPOSES = [
  { key: 'necessary', required: true },
  { key: 'analytics', required: false },
  { key: 'advertising', required: false },
  { key: 'embedded_content', required: false },
];
const base = {
  cmp_id: 528,
  cmp_version: 1,
  gvl_version: 186,
  policy_version: 5,
  publisher_cc: 'FR',
  vendors: [10, 21, 32, 52, 76, 91, 132, 755, 793, 1126],
  purposes: { 1: 'consent', 2: 'legitimate_interest', 3: 'consent', 4: 'consent', 7: 'legitimate_interest', 8: 'off', 9: 'consent', 10: 'legitimate_interest', 11: 'off' },
  special_features: [1, 2],
  stacks: { 1: 'advertising', 2: 'advertising', 3: 'advertising', 4: 'advertising', 7: 'advertising', 9: 'analytics', 10: 'analytics' },
  vendors_url: '/cmp/ATMONA02/vendors-186.json?r=4',
};
const settings = (patch = {}) => ({ ...JSON.parse(JSON.stringify(base)), ...patch });
const all = { analytics: true, advertising: true, embedded_content: true };
const none = { analytics: false, advertising: false, embedded_content: false };

/** The in-app keys of a decision (IAB CMP API v2.2, « In-App Details »): numbers are integers, binary strings carry
 *  « 1 » at index n for id n + 1. */
function keys(m, tc, ac) {
  const bits = (ids, n) => {
    const len = n ?? (ids.length ? Math.max(...ids) : 0);
    let s = '';
    for (let i = 1; i <= len; i++) s += ids.includes(i) ? '1' : '0';
    return s;
  };
  const k = {
    IABTCF_CmpSdkID: m.cmpId,
    IABTCF_CmpSdkVersion: m.cmpVersion,
    IABTCF_PolicyVersion: m.policyVersion,
    IABTCF_gdprApplies: 1,
    IABTCF_PublisherCC: m.publisherCC,
    IABTCF_PurposeOneTreatment: 0,
    IABTCF_UseNonStandardTexts: 0,
    IABTCF_TCString: tc,
    IABTCF_VendorConsents: bits(m.vendorConsents),
    IABTCF_VendorLegitimateInterests: bits(m.vendorLegitimateInterests),
    IABTCF_DisclosedVendors: bits(m.vendorsDisclosed || []),
    IABTCF_PurposeConsents: bits(m.purposeConsents, T.PURPOSES),
    IABTCF_PurposeLegitimateInterests: bits(m.purposeLegitimateInterests, T.PURPOSES),
    IABTCF_SpecialFeaturesOptIns: bits(m.specialFeatureOptins, T.SPECIAL_FEATURES),
    IABTCF_PublisherConsent: bits(m.publisher.consents, T.PURPOSES),
    IABTCF_PublisherLegitimateInterests: bits(m.publisher.legitimateInterests, T.PURPOSES),
    IABTCF_PublisherCustomPurposesConsents: bits(m.publisher.customConsents, m.publisher.numCustom),
    IABTCF_PublisherCustomPurposesLegitimateInterests: bits(m.publisher.customLegitimateInterests, m.publisher.numCustom),
  };
  // Google's Additional Consent (its specification, « In-app »): only for a site with those providers.
  if (ac !== null) k.IABTCF_AddtlConsent = ac;
  // One key per purpose with a restriction: the restriction type of vendor n + 1 at index n, « _ » for none.
  for (let p = 1; p <= T.PURPOSES; p++) {
    const types = {};
    for (const r of m.restrictions) if (r.purpose === p) for (const v of r.vendors) types[v] = r.type;
    const ids = Object.keys(types).map(Number);
    if (!ids.length) continue;
    let s = '';
    for (let i = 1; i <= Math.max(...ids); i++) s += i in types ? String(types[i]) : '_';
    k[`IABTCF_PublisherRestrictions${p}`] = s;
  }
  return k;
}

const cases = [];
function add(name, s, granted, choice, opts = {}) {
  const lang = opts.lang ?? 'fr';
  const vl = opts.list === undefined ? list : opts.list;
  const m = T.buildModel(s, vl, PURPOSES, lang, NOW, granted, choice);
  const tc = T.encode(m);
  const a = T.buildAc(s, vl, m, choice);
  const ac = a ? T.acString(a) : null;
  const back = T.decode(tc);
  if (JSON.stringify(back.vendorConsents) !== JSON.stringify(m.vendorConsents)) throw new Error(`${name}: decode`);
  // The first layer's sentence (cmp/src/tcf/view.ts): the IAB purposes and special features the selected vendors use,
  // said with stacks when purpose 1 is among others.
  let first = null;
  if (vl) {
    const live = s.vendors.map((id) => T.liveVendor(vl, id)).filter(Boolean);
    const providers = T.liveAc(s, vl);
    // Google's providers rest on consent for purposes 1, 3 and 4 (cmp/src/tcf/view.ts `used`).
    const shown = T.range(T.PURPOSES).filter(
      (p) =>
        live.some((v) => T.vendorPurposes(s, v, 'consent').includes(p) || T.vendorPurposes(s, v, 'legitimate_interest').includes(p)) ||
        (providers.length > 0 && T.AC_PURPOSES.includes(p)),
    );
    const sf = s.special_features.filter((f) => live.some((v) => (v.specialFeatures || []).includes(f)));
    const stacked = shown.includes(1) && shown.length > 1;
    first = {
      // The partners the first layer counts: the TCF's and Google's others.
      partners: live.length + providers.length,
      purposes: shown,
      special_features: sf,
      cover: stacked ? T.cover(vl.stacks, shown.slice(1)) : null,
      feature_stack: stacked && sf.length ? T.featureStack(vl.stacks, sf) : null,
    };
  }
  cases.push({
    name,
    settings: s,
    vendor_list: vl ? 'tcf/vendors-186.json' : null,
    lang,
    granted,
    choice: choice ?? null,
    model: m,
    tc,
    ac,
    keys: keys(m, tc, ac),
    first,
  });
  return tc;
}

const accepted = add('accept_all: every banner purpose, every IAB purpose shown, both special features', settings(), all);
add('reject_all: no consent, no legitimate interest, no special feature', settings(), none);
add('custom: advertising only (the IAB purposes grouped under it, purpose 1 included)', settings(), { ...none, advertising: true });
add('custom: analytics only (IAB purposes 9 and 10 grouped under it; no special feature without accept_all)', settings(), { ...none, analytics: true });
add('custom: every banner purpose but one, purpose 1 not grouped follows « all granted »', settings({ stacks: { 2: 'advertising', 3: 'advertising', 4: 'advertising', 7: 'advertising', 9: 'analytics', 10: 'analytics' } }), { ...all, embedded_content: false });
add(
  'preferences: purpose 3 refused, vendor 755 refused, objection to purpose 7 and to vendor 21, special feature 1 only',
  settings(),
  all,
  { vendors: { 755: false }, vendorsLi: { 21: false }, purposesLi: { 7: false }, specialFeatures: { 1: true, 2: false }, purposes: { 3: false } },
);
add('preferences: an explicit vendor consent though its purposes are refused', settings(), none, {
  vendors: { 91: true },
  vendorsLi: {},
  purposesLi: {},
  specialFeatures: {},
  purposes: {},
});
add(
  'publisher restrictions: purpose 2 on consent (flexible vendors on legitimate interest → require consent), 7 off (not allowed), 10 on consent',
  settings({ purposes: { ...base.purposes, 2: 'consent', 7: 'off', 10: 'consent' } }),
  all,
);
add('publisher restrictions: purpose 9 on legitimate interest (flexible vendors on consent → require legitimate interest)', settings({ purposes: { ...base.purposes, 9: 'legitimate_interest' } }), all);
add('legitimate interest on a consent-only purpose (3) counts as off', settings({ purposes: { ...base.purposes, 3: 'legitimate_interest' } }), all);
add('only special feature 2 allowed by the publisher', settings({ special_features: [2] }), all);
add('a selected vendor missing from the list (4) and one the GVL deleted (1500): neither disclosed nor signalled', settings({ vendors: [...base.vendors, 4, 1500].sort((a, b) => a - b) }), all);
add('no vendor list could be read: nothing disclosed, nothing signalled', settings(), all, undefined, { list: null });
add('an invalid publisher country falls back to FR; language pt-BR → PT', settings({ publisher_cc: 'F1' }), all, undefined, { lang: 'pt-BR' });
add('a lower-case publisher country; language zh-Hant → ZH', settings({ publisher_cc: 'be' }), none, undefined, { lang: 'zh-Hant' });
add('a language without two letters → EN', settings(), none, undefined, { lang: '1x' });
add('a single vendor with ranges shorter than its bit field', settings({ vendors: [1126] }), all);
const without793 = add('the publisher had not selected vendor 793 yet', settings({ vendors: base.vendors.filter((v) => v !== 793) }), all);

// Google's other ad tech providers (its Additional Consent list): disclosed when listed, consented with purposes 1, 3, 4.
const AC = [108, 184, 486, 1301, 2572, 3234];
const withAc = (patch = {}) => settings({ ac_providers: AC, ...patch });
const acAccepted = add('Additional Consent: accept_all consents every listed provider', withAc(), all);
const acAcceptedAc = cases[cases.length - 1].ac;
add('Additional Consent: reject_all discloses every listed provider, consents none', withAc(), none);
add('Additional Consent: advertising only (purposes 1, 3 and 4 grouped under it) consents them', withAc(), { ...none, advertising: true });
add('Additional Consent: analytics only, no purpose 3 or 4: disclosed only', withAc(), { ...none, analytics: true });
add('Additional Consent: purpose 4 refused in the preferences: none consented, whatever its switch', withAc(), all, {
  vendors: {},
  vendorsLi: {},
  purposesLi: {},
  specialFeatures: {},
  purposes: { 4: false },
  ac: { 184: true },
});
add('Additional Consent: providers 184 and 3234 refused in the preferences', withAc(), all, {
  vendors: {},
  vendorsLi: {},
  purposesLi: {},
  specialFeatures: {},
  purposes: {},
  ac: { 184: false, 3234: false, 2572: true },
});
add('Additional Consent: a selected provider Google no longer lists (9999): neither disclosed nor consented', withAc({ ac_providers: [...AC, 9999] }), all);
add('Additional Consent: no vendor list could be read: no provider disclosed', withAc(), all, undefined, { list: null });
add('Additional Consent: purpose 3 off for the publisher: no provider consented', withAc({ purposes: { ...base.purposes, 3: 'off' } }), all);
add('Additional Consent: an IAB vendor without purpose 3 (10 alone): the providers bring it', withAc({ vendors: [10] }), all);
add('Additional Consent: the same vendor without providers: purpose 3 neither shown nor signalled', settings({ vendors: [10] }), all);
const acWithout2572 = add('Additional Consent: the publisher had not selected provider 2572 yet', withAc({ ac_providers: AC.filter((id) => id !== 2572) }), all);
const acWithout2572Ac = cases[cases.length - 1].ac;

// The re-ask of a stored string (docs/CMP.md §4.4 rule 5; the vendor list is read when the configuration names
// vendors the string did not disclose). Rules 1–4 (the banner's purposes and revisions) are reask.json's.
const reask = [];
function ask(name, s, stored, expect, vl = list, storedAc = null) {
  let m = null;
  try {
    m = stored ? T.decode(stored) : null;
  } catch {
    m = null;
  }
  let got = T.outdated(s, m);
  if (!got) {
    const missing = s.vendors.filter((id) => !(m.vendorsDisclosed || []).includes(id));
    got = missing.some((id) => T.liveVendor(vl, id));
    // Google's providers likewise: one the stored Additional Consent string does not name, listed now.
    const a = storedAc ? T.parseAc(storedAc) : null;
    const named = a ? [...a.consented, ...a.disclosed] : [];
    const live = T.liveAc(s, vl).map((x) => x.id);
    got = got || (s.ac_providers || []).some((id) => !named.includes(id) && live.includes(id));
  }
  if (got !== expect) throw new Error(`reask ${name}: ${got}`);
  reask.push({ name, settings: s, vendor_list: vl ? 'tcf/vendors-186.json' : null, stored, stored_ac: storedAc, ask: expect });
}
ask('the current string', settings(), accepted, false);
ask('no stored string (TCF turned on after the choice)', settings(), null, true);
ask('an unreadable string', settings(), 'not-a-tc-string', true);
ask('another version 1 string', settings(), 'BOEFEAyOEFEAyAHABDENAI4AAAB9vABAASA', true);
ask('another CMP id', settings({ cmp_id: 300 }), accepted, true);
ask('a new TCF policy version', settings({ policy_version: 6 }), accepted, true);
ask('a new GVL version alone', settings({ gvl_version: 187 }), accepted, false);
ask('the publisher added a vendor of the list', settings(), without793, true);
ask('the publisher added a vendor missing from the list', settings({ vendors: [...base.vendors, 4] }), accepted, false);
ask('the publisher added a vendor the GVL deleted', settings({ vendors: [...base.vendors, 1500] }), accepted, false);
ask('the publisher added a vendor, the list could not be read', settings(), without793, false, null);
ask('the publisher removed a vendor', settings({ vendors: base.vendors.filter((v) => v !== 10) }), accepted, false);
ask('Additional Consent: the current strings', withAc(), acAccepted, false, list, acAcceptedAc);
ask('Additional Consent: providers selected after the choice (no string)', withAc(), accepted, true);
ask('Additional Consent: the publisher added a provider of the list', withAc(), acWithout2572, true, list, acWithout2572Ac);
ask('Additional Consent: the publisher added a provider Google no longer lists', withAc({ ac_providers: [...AC, 9999] }), acAccepted, false, list, acAcceptedAc);
ask('Additional Consent: the publisher removed a provider', withAc({ ac_providers: AC.filter((id) => id !== 108) }), acAccepted, false, list, acAcceptedAc);
ask('Additional Consent: a disclosed, refused provider stays named', withAc(), cases.find((c) => c.name.startsWith('Additional Consent: reject_all')).tc, false, list, '2~~dv.' + AC.join('.'));
ask('Additional Consent: a version 1 string names consented providers only', withAc({ ac_providers: [108, 184] }), acAccepted, false, list, '1~108.184');
ask('Additional Consent: the publisher added a provider, the list could not be read', withAc(), acWithout2572, false, null, acWithout2572Ac);

const doc = {
  about:
    'Generated by tcf-vectors.mjs from the site script\'s TCF code (cmp/src/tcf): the TC model, TC string and in-app keys of each decision, and the re-ask of a stored string. See README.md.',
  now: NOW,
  purposes: PURPOSES,
  cases,
  reask,
};
const text = JSON.stringify(doc, null, 1) + '\n';
const file = join(here, 'tcf-vectors.json');
if (process.argv.includes('--check')) {
  if (!existsSync(file) || readFileSync(file, 'utf8') !== text) {
    console.error('tcf-vectors.json is out of date: node sdk/protocol/cmp/tcf-vectors.mjs');
    process.exit(1);
  }
  console.log(`tcf-vectors.json: ${cases.length} cases, ${reask.length} re-asks, up to date`);
} else {
  writeFileSync(file, text);
  console.log(`tcf-vectors.json: ${cases.length} cases, ${reask.length} re-asks`);
}
