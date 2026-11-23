import * as React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { Scruter } from '@scruter/react-native';
import { cmp } from './config';
import { Checkout } from './screens/Checkout';
import { Home } from './screens/Home';
import { Product } from './screens/Product';
import { Products } from './screens/Products';
import { Privacy } from './screens/Privacy';
import { Settings } from './screens/Settings';

export type Routes = {
  Home: undefined;
  Products: undefined;
  Product: { id: number };
  Checkout: undefined;
  Settings: undefined;
  Privacy: undefined;
};

const Stack = createNativeStackNavigator<Routes>();

export default function App() {
  return (
    <NavigationContainer ref={Scruter.navigationRef}>
      <Stack.Navigator>
        <Stack.Screen name="Home" component={Home} />
        <Stack.Screen name="Products" component={Products} />
        <Stack.Screen name="Product" component={Product} />
        <Stack.Screen name="Checkout" component={Checkout} />
        <Stack.Screen name="Settings" component={Settings} />
        {cmp ? <Stack.Screen name="Privacy" component={Privacy} /> : null}
      </Stack.Navigator>
    </NavigationContainer>
  );
}
