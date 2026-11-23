import type { Spec } from './specs/NativeScruter';

/** A frame as the native layers take it (docs/API.md §5.3): function, file, line, column, in the app. */
export interface Frame {
  fn?: string;
  fl?: string;
  l?: number;
  co?: number;
  ia?: 1;
}

const MAX_FRAMES = 64;
const MAX_TEXT = 200;
// Hermes and V8: `at fn (file:1:2)`, `at file:1:2`, `at fn (address at file:1:2)`, `at fn (native)`.
const V8 = /^\s*at (?:(.*?) ?\()?(?:address at )?(.*?)(?::(\d+):(\d+))?\)?$/;
// JavaScriptCore: `fn@file:1:2`, `@file:1:2`, `fn@[native code]`, `global code@file:1:2`.
const JSC = /^(.*?)@(.*?)(?::(\d+):(\d+))?$/;

/** The file's own name: a path on the phone holds the app's container id, and a dev server's URL its query. */
function fileName(raw: string): string {
  const path = raw.split(/[?#]/)[0] ?? raw;
  return path.substring(path.lastIndexOf('/') + 1).slice(0, MAX_TEXT);
}

function frame(fn: string | undefined, file: string | undefined, line?: string, column?: string): Frame {
  const f: Frame = {};
  if (fn && fn !== '?' && fn !== 'anonymous') f.fn = fn.slice(0, MAX_TEXT);
  const native = !file || file === 'native' || file === '[native code]';
  if (!native) {
    const name = fileName(file);
    if (name) f.fl = name;
    if (line !== undefined) f.l = Number(line);
    if (column !== undefined) f.co = Number(column);
    f.ia = 1;
  }
  return f;
}

/** The frames of an error's stack (Hermes, JavaScriptCore, V8), most recent first; never empty. */
export function parseStack(stack: unknown): Frame[] {
  const out: Frame[] = [];
  if (typeof stack === 'string') {
    for (const line of stack.split('\n')) {
      if (out.length >= MAX_FRAMES) break;
      const v8 = /^\s*at /.test(line) ? V8.exec(line) : null;
      if (v8) {
        out.push(frame(v8[1], v8[2], v8[3], v8[4]));
        continue;
      }
      if (!line.includes('@') || line.startsWith(' ')) continue;
      const jsc = JSC.exec(line);
      if (jsc) out.push(frame(jsc[1], jsc[2], jsc[3], jsc[4]));
    }
  }
  return out.length ? out : [{ fn: '?' }];
}

interface ErrorUtilsLike {
  getGlobalHandler?(): ((error: unknown, isFatal?: boolean) => void) | undefined;
  setGlobalHandler?(handler: (error: unknown, isFatal?: boolean) => void): void;
}

type Described = { name?: unknown; message?: unknown; stack?: unknown };

/** Type and reason of what was thrown, ≤ 200 characters each; the server masks the reason again. */
export function describe(error: unknown): { type: string; reason: string } {
  const e = (typeof error === 'object' && error !== null ? error : {}) as Described;
  const type = typeof e.name === 'string' && e.name ? e.name : 'Error';
  const reason = typeof e.message === 'string' ? e.message : typeof error === 'string' ? error : '';
  return { type: type.slice(0, MAX_TEXT), reason: reason.slice(0, MAX_TEXT) };
}

/**
 * Chains `ErrorUtils.setGlobalHandler` (docs/MOBILE.md §3.10): the previous handler always runs, after the report. It
 * ends the process on a fatal error in a release build, so the report is written synchronously first. In `__DEV__` a
 * fatal error only shows the red screen: it is a `nonfatal`.
 */
export function installErrorHandler(native: Spec, dev: boolean, utils: ErrorUtilsLike | undefined): void {
  if (!utils?.setGlobalHandler) return;
  const previous = utils.getGlobalHandler?.();
  let bundleId = '';
  utils.setGlobalHandler((error, isFatal) => {
    try {
      bundleId ||= currentBundleId(native);
      const { type, reason } = describe(error);
      const frames = parseStack((error as Described | null | undefined)?.stack);
      native.reportError(Boolean(isFatal) && !dev, type, reason, frames as Object[], bundleId);
    } catch {
      // Never stand between the app and its error handling.
    }
    previous?.(error, isFatal);
  });
}

/** The id `withScruter` wrote into the bundle, else the build's (docs/MOBILE.md §20). */
export function currentBundleId(native: Spec): string {
  const id = (globalThis as { __SCRUTER_DEBUG_ID__?: unknown }).__SCRUTER_DEBUG_ID__;
  return typeof id === 'string' && id ? id : native.defaultBundleId();
}
