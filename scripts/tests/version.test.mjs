// version.mjs on a copy of the targets. Run: node --test scripts/tests/version.test.mjs
import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { PUBLISHED_TARGETS, SDK_TARGETS, markPublished, problems, read, setVersion } from '../version.mjs';

const sdk = join(dirname(fileURLToPath(import.meta.url)), '../..');
let base;

function copyTree() {
  const root = mkdtempSync(join(base, 'sdk-'));
  const sub = join(root, 'sdk');
  for (const file of ['VERSION', 'CHANGELOG.md', 'flutter/CHANGELOG.md', ...SDK_TARGETS.map((t) => t.file)]) {
    if (!existsSync(join(sdk, file))) continue;
    mkdirSync(dirname(join(sub, file)), { recursive: true });
    cpSync(join(sdk, file), join(sub, file));
  }
  return sub;
}

function addMonorepo(sub, version = '1.0.0') {
  for (const target of PUBLISHED_TARGETS) {
    const path = join(sub, target.file);
    mkdirSync(dirname(path), { recursive: true });
    const lines = target.file.endsWith('.rs')
      ? ['ios', 'android', 'react_native', 'flutter'].map((p) => `("${p}", "${version}"),`).join('\n')
      : `id("net.scruter.symbols") version "${version}"\nnet.scruter:scruter-android:${version}\n`;
    writeFileSync(path, lines);
  }
}

before(() => {
  base = mkdtempSync(join(tmpdir(), 'scruter-version-'));
});
after(() => rmSync(base, { recursive: true, force: true }));

test('every target of this tree says VERSION', () => {
  assert.deepEqual(problems(sdk), []);
});

test('a target that moved is an error, not a silent skip', () => {
  const sub = copyTree();
  const path = join(sub, 'flutter/pubspec.yaml');
  writeFileSync(path, readFileSync(path, 'utf8').replace(/^version: /m, 'versions: '));
  assert.throws(() => problems(sub), /flutter\/pubspec\.yaml/);
});

test('a manifest out of line is reported', () => {
  const sub = copyTree();
  const path = join(sub, 'Scruter.podspec');
  writeFileSync(path, readFileSync(path, 'utf8').replace(/s\.version(\s*)= '[^']+'/, "s.version$1= '0.9.0'"));
  assert.deepEqual(problems(sub), [`Scruter.podspec: 0.9.0, VERSION says ${readFileSync(join(sub, 'VERSION'), 'utf8').trim()}`]);
});

test('set writes every target, and only the versions', () => {
  const sub = copyTree();
  const before = readFileSync(join(sub, 'flutter/pubspec.yaml'), 'utf8');
  const was = readFileSync(join(sub, 'VERSION'), 'utf8').trim();
  setVersion(sub, '1.2.3');
  assert.equal(readFileSync(join(sub, 'VERSION'), 'utf8'), '1.2.3\n');
  for (const target of SDK_TARGETS) {
    if (existsSync(join(sub, target.file))) assert.ok(read(sub, target).every((v) => v === '1.2.3'), target.file);
  }
  assert.equal(readFileSync(join(sub, 'flutter/pubspec.yaml'), 'utf8'), before.replace(`version: ${was}`, 'version: 1.2.3'));
  assert.ok(readFileSync(join(sub, 'flutter/lib/src/scruter.dart'), 'utf8').includes("'1.2.3'"));
});

test('set refuses anything but x.y.z', () => {
  const sub = copyTree();
  assert.throws(() => setVersion(sub, '1.2'), /not x\.y\.z/);
  assert.throws(() => setVersion(sub, 'v1.2.3'), /not x\.y\.z/);
  assert.throws(() => setVersion(sub, '1.2.3-rc.1'), /not x\.y\.z/);
});

test('a new version needs its changelog sections', () => {
  const sub = copyTree();
  setVersion(sub, '1.2.3');
  assert.deepEqual(problems(sub), ['CHANGELOG.md: no "## 1.2.3" section', 'flutter/CHANGELOG.md: no "## 1.2.3" section']);
});

test('LATEST_SDK may trail VERSION until the publication, never pass it', () => {
  const sub = copyTree();
  addMonorepo(sub);
  assert.deepEqual(problems(sub), []);
  setVersion(sub, '1.2.3');
  for (const file of ['CHANGELOG.md', 'flutter/CHANGELOG.md']) writeFileSync(join(sub, file), '## 1.2.3\n\nNew.\n');
  assert.deepEqual(problems(sub), []);
  addMonorepo(sub, '1.2.10');
  assert.equal(problems(sub).length, PUBLISHED_TARGETS.reduce((n, t) => n + (t.count ?? 1), 0));
});

test('latest writes LATEST_SDK and the public docs from VERSION', () => {
  const sub = copyTree();
  addMonorepo(sub);
  setVersion(sub, '1.2.3');
  markPublished(sub);
  for (const target of PUBLISHED_TARGETS) assert.ok(read(sub, target).every((v) => v === '1.2.3'), target.file);
});

test('latest refuses to run without the monorepo', () => {
  assert.throws(() => markPublished(copyTree()), /monorepo/);
});
