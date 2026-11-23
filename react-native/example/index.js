import { AppRegistry, LogBox } from 'react-native';
import { Scruter, ScruterCMP } from '@scruter/react-native';
import App from './src/App';
import { cmp, config } from './src/config';
import { wirePartners } from './src/partners';

// Scruter CMP first: the app's optional SDKs wait for its answer (CMP.md). Scruter Analytics is exempt and never waits.
if (cmp) {
  // The device check drives a debug build: no development overlay over the buttons it taps.
  if (cmp.endpoint) LogBox.ignoreAllLogs();
  ScruterCMP.debug = cmp.debug;
  ScruterCMP.start({ appId: cmp.appId, endpoint: cmp.endpoint });
  wirePartners();
}

if (config.analytics !== false) {
  const began = performance.now();
  Scruter.start(config);
  const started = performance.now();
  Scruter.track('SDK timing', { props: { start_ms: (started - began).toFixed(2) } });
  const tracked = performance.now();
  Scruter.track('SDK timing', { props: { track_ms: (tracked - started).toFixed(2) } });
}

AppRegistry.registerComponent('ScruterExample', () => App);
