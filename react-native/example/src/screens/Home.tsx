import * as React from 'react';
import { Text, View } from 'react-native';
import { Scruter } from '@scruter/react-native';
import { Button } from '../ui';

export function Home({ navigation }: { navigation: { navigate(route: string): void } }) {
  return (
    <View testID="home" style={{ flex: 1, padding: 16 }}>
      <Text testID="welcome">Atelier Mona</Text>
      <Button testID="open_products" title="Shop" onPress={() => navigation.navigate('Products')} />
      <Button testID="open_checkout" title="Checkout" onPress={() => navigation.navigate('Checkout')} />
      <Button testID="open_settings" title="Settings" onPress={() => navigation.navigate('Settings')} />
      <Button testID="welcome_event" title="Say hello" onPress={() => Scruter.track('Hello', { props: { from: 'home', n: 1 } })} />
    </View>
  );
}
