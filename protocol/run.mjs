// Conformance runner (docs/MOBILE.md §4): posts every golden fixture to a running ingest and checks the answers, after
// checking each fixture's body against its JSON Schema. Node ≥ 20, no dependency.
//
//   node run.mjs --ingest http://127.0.0.1:4100 --app ATMONA02 [--only batch/valid] [--schemas-only]
//
// The app must exist with the conformance identifiers (README.md): iOS bundle id and Android package
// `fr.scruter.conformance`, macOS bundle id `fr.scruter.conformance.mac`, App Store id 525463029, time zone Europe/Paris, ignored versions `0.9.*`, a workspace in
// its trial (full collection). Placeholders: {{APP}}, {{BATCH}}, {{BATCH2}}, {{SESSION}}, {{DAILY}} (random per
// fixture), {{TODAY}} (Europe/Paris), {{NOW}}, {{NOW-<ms>}}, {{NOW+<ms>}} (numbers).
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { randomBytes } from 'node:crypto';
import { validate } from './validate.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => {
    if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
    return acc;
  }, []),
);
const ingest = (args.ingest || 'http://127.0.0.1:4100').replace(/\/$/, '');
const app = args.app || 'ATMONA02';
const schemasOnly = Boolean(args['schemas-only']);

function files(dir) {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? files(p) : p.endsWith('.json') ? [p] : [];
  });
}

const hex = (n) => randomBytes(n).toString('hex');
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Paris' }).format(new Date());

/** Replaces the placeholders of a fixture (one set of random ids per fixture). */
export function instantiate(value, vars) {
  if (typeof value === 'string') {
    const num = value.match(/^\{\{NOW([+-]\d+)?\}\}$/);
    if (num) return vars.now + Number(num[1] || 0);
    return value.replace(/\{\{(\w+)\}\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
  }
  if (Array.isArray(value)) return value.map((v) => instantiate(v, vars));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, instantiate(v, vars)]));
  return value;
}

function body(req) {
  if (req.raw !== undefined) return Buffer.from(req.raw);
  let json = req.json;
  if (req.pad_bytes) json = { ...json, pad: 'x'.repeat(req.pad_bytes) };
  const raw = Buffer.from(JSON.stringify(json));
  return req.gzip ? gzipSync(raw) : raw;
}

/** The value with its object keys sorted: JSON objects have no order, and answers may come in any. */
function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])]));
  return v;
}
const same = (a, b) => JSON.stringify(sorted(a)) === JSON.stringify(sorted(b));

function subset(expected, actual) {
  return Object.entries(expected).every(([k, v]) => same(actual?.[k], v));
}

let failed = 0;
let passed = 0;
const root = join(here, 'fixtures');
for (const file of files(root).sort()) {
  const name = relative(root, file).replace(/\.json$/, '');
  if (args.only && !name.startsWith(args.only)) continue;
  const fixture = JSON.parse(readFileSync(file, 'utf8'));
  const vars = { APP: app, BATCH: hex(16), BATCH2: hex(16), SESSION: hex(8), DAILY: hex(16), TODAY: today(), now: Date.now() };
  const problems = [];
  for (const [i, step] of fixture.steps.entries()) {
    const req = instantiate(step.request, vars);
    if (fixture.schema === 'batch' && req.json) {
      const errors = validate('batch', req.json);
      if (fixture.valid && errors.length) problems.push(`step ${i + 1}: body fails the schema: ${errors.slice(0, 3).join('; ')}`);
      if (!fixture.valid && name.includes('invalid') && errors.length === 0 && !req.pad_bytes) {
        problems.push(`step ${i + 1}: an invalid fixture passes the schema`);
      }
    }
    if (schemasOnly) continue;
    const headers = { ...(req.headers || {}) };
    if (req.gzip) headers['content-encoding'] = 'gzip';
    let res;
    try {
      res = await fetch(ingest + req.path, { method: req.method, headers, body: req.method === 'GET' ? undefined : body(req) });
    } catch (e) {
      problems.push(`step ${i + 1}: ${e.message}`);
      break;
    }
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    const exp = step.expect;
    if (res.status !== exp.status) problems.push(`step ${i + 1}: status ${res.status}, expected ${exp.status} (${text.slice(0, 200)})`);
    if (exp.json !== undefined && !same(json, exp.json)) problems.push(`step ${i + 1}: body ${text.slice(0, 200)}, expected ${JSON.stringify(exp.json)}`);
    if (exp.json_subset && !subset(exp.json_subset, json)) problems.push(`step ${i + 1}: body ${text.slice(0, 200)} lacks ${JSON.stringify(exp.json_subset)}`);
    if (exp.error_code && json?.error?.code !== exp.error_code) problems.push(`step ${i + 1}: error ${json?.error?.code}, expected ${exp.error_code}`);
    if (fixture.schema === 'config' && res.status === 200 && json) {
      const errors = validate('config', json);
      if (errors.length) problems.push(`step ${i + 1}: answer fails config.schema.json: ${errors.join('; ')}`);
    }
  }
  if (problems.length) {
    failed++;
    console.log(`FAIL ${name}\n  ${problems.join('\n  ')}`);
  } else {
    passed++;
    console.log(`ok   ${name}`);
  }
}
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
