import * as React from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { ScruterMask, ScruterView } from '@scruter/react-native';
import { Button } from '../ui';

export function Product({ navigation }: { navigation: { navigate(route: string): void } }) {
  return (
    <ScrollView testID="product">
      <View nativeID="gallery" style={{ backgroundColor: '#E4DDFF', height: 320 }}>
        <Text>Gallery</Text>
      </View>
      <ScruterMask testID="address" style={{ backgroundColor: '#FFF3CF', padding: 24 }}>
        <Text>Morgan Smith, 12 Lilac Street, London</Text>
      </ScruterMask>
      <View testID="web_block" style={{ height: 120 }}>
        <WebView testID="web" accessibilityRole="image" source={{ html: '<p>Terms of sale</p>' }} />
      </View>
      <ScruterView scruterIgnore style={{ padding: 24 }}>
        <Text testID="ignored">An area left out of taps and images</Text>
      </ScruterView>
      <Pressable testID="holder" onPress={() => {}}>
        <ScruterMask>
          <Text>Inside a mask, inside a press</Text>
        </ScruterMask>
      </Pressable>
      <View style={{ height: 900, padding: 24 }}>
        <Text testID="plain_text">A long description nobody can tap.</Text>
      </View>
      <ScruterView scruterId="buy_block">
        <Button testID="buy" title="Buy" onPress={() => navigation.navigate('Checkout')} />
      </ScruterView>
    </ScrollView>
  );
}
