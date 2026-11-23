import * as React from 'react';
import { Switch, Text, TextInput, View } from 'react-native';
import { Scruter, ScruterView } from '@scruter/react-native';
import { Button } from '../ui';

const input = { borderColor: '#E6E3EE', borderRadius: 8, borderWidth: 1, margin: 8, padding: 10 };

export function Checkout({ navigation }: { navigation: { navigate(route: string): void } }) {
  const [postal, setPostal] = React.useState('');
  const [gift, setGift] = React.useState(false);
  const submit = () => {
    if (!/^\d{5}$/.test(postal)) {
      Scruter.fieldError('postal_code', 'format');
      return;
    }
    Scruter.formSent('Delivery');
    navigation.navigate('Home');
  };
  return (
    <ScruterView testID="checkout" scruterForm="Delivery" style={{ flex: 1, padding: 16 }}>
      <TextInput testID="postal_code" placeholder="Postal code" style={input} value={postal} onChangeText={setPostal} keyboardType="number-pad" />
      <TextInput placeholder="E-mail" style={input} textContentType="emailAddress" autoComplete="email" autoCapitalize="none" />
      <TextInput testID="password" placeholder="Password" style={input} secureTextEntry />
      <View style={{ alignItems: 'center', flexDirection: 'row', margin: 8 }}>
        <Text>Gift</Text>
        <Switch testID="gift" value={gift} onValueChange={setGift} />
      </View>
      <Button testID="submit" title="Send" onPress={submit} />
    </ScruterView>
  );
}
