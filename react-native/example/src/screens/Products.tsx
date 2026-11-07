import * as React from 'react';
import { FlatList, Pressable, Text, View } from 'react-native';
import { Scruter } from '@scruter/react-native';

const ITEMS = Array.from({ length: 200 }, (_, i) => ({ id: i, name: `Product ${i}` }));

export function Products({ navigation }: { navigation: { navigate(route: string, params: { id: number }): void } }) {
  return (
    <FlatList
      testID="products"
      data={ITEMS}
      keyExtractor={(item) => String(item.id)}
      renderItem={({ item }) => (
        <Pressable testID="product_row" accessible={false} onPress={() => navigation.navigate('Product', { id: item.id })}>
          <View style={{ alignItems: 'center', flexDirection: 'row', height: 72, justifyContent: 'space-between', padding: 12 }}>
            <Text>{item.name}</Text>
            <Pressable
              testID="add_to_cart"
              style={{ backgroundColor: '#6B4EFF', borderRadius: 8, padding: 10 }}
              onPress={() => Scruter.track('Add to cart', { props: { product: item.id }, revenue: 49, currency: 'EUR' })}
            >
              <Text style={{ color: '#fff' }}>Add</Text>
            </Pressable>
          </View>
        </Pressable>
      )}
    />
  );
}
