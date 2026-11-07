import * as React from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

export function Button({ title, testID, onPress }: { title: string; testID: string; onPress: () => void }) {
  return (
    <Pressable testID={testID} style={styles.button} onPress={onPress}>
      <Text style={styles.label}>{title}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: { backgroundColor: '#17131F', borderRadius: 12, margin: 8, padding: 14 },
  label: { color: '#fff', fontSize: 16, textAlign: 'center' },
});
