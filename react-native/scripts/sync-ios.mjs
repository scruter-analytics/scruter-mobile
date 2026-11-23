#!/usr/bin/env node
// Copies the iOS SDK into the package at pack time: the pod ScruterReactNative compiles it itself, because CocoaPods
// trunk turns read-only on 2026-12-02 and a trunk pod could never receive a fix (docs/MOBILE.md §20). `ios/sdk/` is
// generated; `../ios/Sources` stays the only source. The upload script travels with it, for the CLI's hand-off.
import { chmodSync, cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
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
cpSync(join(root, '../ios/upload-symbols'), join(target, 'upload-symbols'));
chmodSync(join(target, 'upload-symbols'), 0o755);
console.log('iOS SDK copied to ios/sdk');
