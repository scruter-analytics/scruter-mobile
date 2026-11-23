import * as React from 'react';
import { Switch, Text, View } from 'react-native';
import { Scruter } from '@scruter/react-native';
import { Button } from '../ui';

function explodeNow(): never {
  throw new TypeError('The example crashes on purpose');
}

export function Settings() {
  const [measured, setMeasured] = React.useState(!Scruter.isOptedOut);
  const toggle = (on: boolean) => {
    if (on) Scruter.optIn();
    else Scruter.optOut();
    setMeasured(on);
  };
  return (
    <View testID="settings" style={{ flex: 1, padding: 16 }}>
      <View style={{ alignItems: 'center', flexDirection: 'row', margin: 8 }}>
        <Text>Audience measurement</Text>
        <Switch testID="measurement" value={measured} onValueChange={toggle} />
      </View>
      <Button
        testID="soft_error"
        title="Report a non-fatal error"
        onPress={() => (globalThis as { ErrorUtils?: { reportError(e: Error): void } }).ErrorUtils?.reportError(new Error('A non-fatal error'))}
      />
      <Button testID="crash_js" title="Crash in JavaScript" onPress={() => setTimeout(explodeNow, 0)} />
    </View>
  );
}
