#!/usr/bin/env node
// Copies the iOS SDK into the package at pack time: the pod ScruterReactNative compiles it itself, because CocoaPods
// trunk turns read-only on 2026-12-02 and a trunk pod could never receive a fix (docs/MOBILE.md §20). `ios/sdk/` is
// generated; `../ios/Sources` stays the only source. The upload script travels with it, for the CLI's hand-off.
import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const sources = join(root, '../ios/Sources');
const target = join(root, 'ios/sdk');
if (!existsSync(sources)) throw new Error(`${sources} not found: the package is packed from the scruter-mobile repository`);
rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });
cpSync(join(sources, 'ScruterAnalytics'), join(target, 'ScruterAnalytics'), { recursive: true });
cpSync(join(sources, 'ScruterCrash'), join(target, 'ScruterCrash'), { recursive: true });
// Scruter CMP: compiled only for an app whose package.json asks for it (ScruterReactNative.podspec).
cpSync(join(sources, 'ScruterCMP'), join(target, 'ScruterCMP'), { recursive: true });
cpSync(join(root, '../ios/upload-symbols'), join(target, 'upload-symbols'));
chmodSync(join(target, 'upload-symbols'), 0o755);
// With both modules, the pod compiles Scruter Analytics, Scruter CMP and this package's Swift into one module, where a
// file name may appear once (docs/CMP-MOBILE.md §3.16).
const swift = (dir) =>
  readdirSync(dir).flatMap((f) => {
    const path = join(dir, f);
    if (path === target) return [];
    return statSync(path).isDirectory() ? swift(path) : f.endsWith('.swift') ? [f] : [];
  });
const names = [...swift(join(target, 'ScruterAnalytics')), ...swift(join(target, 'ScruterCMP')), ...swift(join(root, 'ios'))];
const twice = names.filter((n, i) => names.indexOf(n) !== i);
if (twice.length) throw new Error(`Swift file names used twice in one module: ${[...new Set(twice)].join(', ')}`);
console.log('iOS SDK copied to ios/sdk');
