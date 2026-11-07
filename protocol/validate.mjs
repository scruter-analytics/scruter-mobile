// A small JSON Schema (2020-12) validator for the protocol's schemas: the keywords they use, no dependency, so that
// every SDK's CI (Node ≥ 20) can check its payloads. `node validate.mjs batch payload.json` validates a file;
// `validate(schemaName, value, defName?)` is the module API used by run.mjs.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

export function loadSchema(name) {
  return JSON.parse(readFileSync(join(here, 'schema', `${name}.schema.json`), 'utf8'));
}

const typeOf = (v) =>
  v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v;

function typeMatches(t, v) {
  const actual = typeOf(v);
  return t === actual || (t === 'number' && actual === 'integer');
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function check(root, schema, v, path, errors) {
  if (schema === true) return;
  if (schema === false) return errors.push(`${path}: not allowed`);
  if (schema.$ref) {
    const ref = schema.$ref.replace(/^#\//, '').split('/');
    let target = root;
    for (const part of ref) target = target?.[part];
    if (!target) return errors.push(`${path}: unresolved ${schema.$ref}`);
    check(root, target, v, path, errors);
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => typeMatches(t, v))) return errors.push(`${path}: expected ${types.join('|')}, got ${typeOf(v)}`);
  }
  if ('const' in schema && !deepEqual(schema.const, v)) errors.push(`${path}: must be ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.some((e) => deepEqual(e, v))) errors.push(`${path}: not one of ${JSON.stringify(schema.enum)}`);
  if (typeof v === 'string') {
    const len = [...v].length;
    if (schema.minLength !== undefined && len < schema.minLength) errors.push(`${path}: shorter than ${schema.minLength}`);
    if (schema.maxLength !== undefined && len > schema.maxLength) errors.push(`${path}: longer than ${schema.maxLength}`);
    if (schema.pattern && !new RegExp(schema.pattern, 'u').test(v)) errors.push(`${path}: does not match ${schema.pattern}`);
  }
  if (typeof v === 'number') {
    if (schema.minimum !== undefined && v < schema.minimum) errors.push(`${path}: below ${schema.minimum}`);
    if (schema.maximum !== undefined && v > schema.maximum) errors.push(`${path}: above ${schema.maximum}`);
    if (schema.exclusiveMinimum !== undefined && v <= schema.exclusiveMinimum) errors.push(`${path}: not above ${schema.exclusiveMinimum}`);
    if (schema.multipleOf !== undefined && v % schema.multipleOf !== 0) errors.push(`${path}: not a multiple of ${schema.multipleOf}`);
  }
  if (Array.isArray(v)) {
    if (schema.minItems !== undefined && v.length < schema.minItems) errors.push(`${path}: fewer than ${schema.minItems} items`);
    if (schema.maxItems !== undefined && v.length > schema.maxItems) errors.push(`${path}: more than ${schema.maxItems} items`);
    const prefix = schema.prefixItems || [];
    v.forEach((item, i) => {
      const s = i < prefix.length ? prefix[i] : schema.items;
      if (s !== undefined) check(root, s, item, `${path}[${i}]`, errors);
    });
  }
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    const keys = Object.keys(v);
    for (const r of schema.required || []) if (!(r in v)) errors.push(`${path}: missing ${r}`);
    if (schema.maxProperties !== undefined && keys.length > schema.maxProperties) errors.push(`${path}: more than ${schema.maxProperties} properties`);
    for (const k of keys) {
      if (schema.propertyNames) check(root, schema.propertyNames, k, `${path}.<${k}>`, errors);
      if (schema.properties && k in schema.properties) check(root, schema.properties[k], v[k], `${path}.${k}`, errors);
      else if (schema.additionalProperties !== undefined) check(root, schema.additionalProperties, v[k], `${path}.${k}`, errors);
    }
  }
  if (schema.oneOf) {
    const ok = schema.oneOf.filter((s) => { const e = []; check(root, s, v, path, e); return e.length === 0; }).length;
    if (ok !== 1) errors.push(`${path}: must match exactly one of oneOf (matched ${ok})`);
  }
  if (schema.not) {
    const e = []; check(root, schema.not, v, path, e);
    if (e.length === 0) errors.push(`${path}: must not match`);
  }
  if (schema.if) {
    const e = []; check(root, schema.if, v, path, e);
    if (e.length === 0 && schema.then) check(root, schema.then, v, path, errors);
    if (e.length > 0 && schema.else) check(root, schema.else, v, path, errors);
  }
}

/** Errors (empty when valid) of `value` against schema `name` (or its `$defs[defName]`). */
export function validate(name, value, defName) {
  const root = loadSchema(name);
  const schema = defName ? root.$defs[defName] : root;
  const errors = [];
  check(root, schema, value, '$', errors);
  return errors;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [name, file, def] = process.argv.slice(2);
  if (!name || !file) {
    console.error('usage: node validate.mjs <batch|config|team-register|team-screen|symbols> <file.json> [$defs name]');
    process.exit(2);
  }
  const errors = validate(name, JSON.parse(readFileSync(file, 'utf8')), def);
  if (errors.length) {
    for (const e of errors) console.error(e);
    process.exit(1);
  }
  console.log('valid');
}
