import { AppRegistry } from 'react-native';
import { Scruter } from '@scruter/react-native';
import App from './src/App';
import { config } from './src/config';

const began = performance.now();
Scruter.start(config);
const started = performance.now();
Scruter.track('SDK timing', { props: { start_ms: (started - began).toFixed(2) } });
const tracked = performance.now();
Scruter.track('SDK timing', { props: { track_ms: (tracked - started).toFixed(2) } });

AppRegistry.registerComponent('ScruterExample', () => App);
