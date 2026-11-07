/** The parts of a React Navigation container (6 and 7) the SDK reads: no dependency on the library. */
export interface NavigationContainer {
  addListener(event: 'state' | 'ready', callback: () => void): (() => void) | undefined;
  getCurrentRoute?(): { key?: string; name: string } | undefined;
  getRootState?(): NavState | undefined;
  isReady?(): boolean;
}

interface NavRoute {
  key?: string;
  name: string;
  state?: NavState;
}

interface NavState {
  type?: string;
  index?: number;
  routes?: NavRoute[];
}

export type NavigationRefLike = NavigationContainer | { current: NavigationContainer | null };

/** The focused routes, from the root to the screen, and the keys of every route the state holds. */
function read(state: NavState | undefined): { chain: NavRoute[]; leaf?: NavState; keys: Set<string> } {
  const chain: NavRoute[] = [];
  const keys = new Set<string>();
  let leaf: NavState | undefined;
  const collect = (s: NavState) => {
    for (const r of s.routes ?? []) {
      if (r.key) keys.add(r.key);
      if (r.state) collect(r.state);
    }
  };
  if (state) collect(state);
  let s = state;
  while (s?.routes?.length) {
    leaf = s;
    const r: NavRoute | undefined = s.routes[s.index ?? s.routes.length - 1];
    if (!r) break;
    chain.push(r);
    s = r.state;
  }
  return { chain, leaf, keys };
}

/**
 * The screen's name: the route's `name`, never its `params`. Expo Router names a folder's screen `index`, in every
 * folder: such a route takes its folder's name (route groups such as `(tabs)` say nothing).
 */
export function screenName(chain: string[]): string | undefined {
  const last = chain[chain.length - 1];
  if (last === undefined) return undefined;
  if (last !== 'index') return isStructure(last) ? undefined : last;
  for (let i = chain.length - 2; i >= 0; i--) {
    const name = chain[i] as string;
    if (!isStructure(name)) return name;
  }
  return last;
}

/** Expo Router's root and its route groups: they organise routes, no one sees them. */
function isStructure(name: string): boolean {
  return name === '__root' || /^\(.*\)$/.test(name);
}

/** An app's name for a route: a string replaces it, `null` leaves the route uncounted, `undefined` keeps it. */
export type ScreenNamer = (route: string) => string | null | undefined;

function named(name: string | undefined, namer: ScreenNamer | undefined): string | undefined {
  if (name === undefined || !namer) return name;
  try {
    const given = namer(name);
    return given === undefined ? name : given ?? undefined;
  } catch {
    return name;
  }
}

/** Reports each focused route; returns what stops it. `report(name, forward)`: `forward` for a push, §3.9. */
export function track(
  ref: NavigationRefLike,
  report: (name: string, forward: boolean) => void,
  namer?: ScreenNamer,
): () => void {
  const nav = (('current' in ref ? ref.current : ref) ?? undefined) as NavigationContainer | undefined;
  if (!nav?.addListener) return () => {};
  let lastKey: string | undefined;
  let known = new Set<string>();
  const check = () => {
    if (nav.isReady && !nav.isReady()) return;
    const { chain, leaf, keys } = read(nav.getRootState?.());
    const route = chain[chain.length - 1] ?? nav.getCurrentRoute?.();
    if (!route) return;
    const key = route.key ?? route.name;
    if (key === lastKey) {
      known = keys;
      return;
    }
    const pushed = lastKey !== undefined && !known.has(key) && (leaf?.index ?? 0) > 0;
    const forward = pushed && leaf?.type !== 'tab' && leaf?.type !== 'drawer';
    lastKey = key;
    known = keys;
    const name = named(screenName(chain.length ? chain.map((r) => r.name) : [route.name]), namer);
    if (name) report(name, forward);
  };
  const stops = [nav.addListener('state', check), nav.addListener('ready', check)];
  check();
  return () => stops.forEach((stop) => stop?.());
}
