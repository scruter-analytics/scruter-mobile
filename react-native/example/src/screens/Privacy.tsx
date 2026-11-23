import * as React from 'react';
import { DevSettings, ScrollView, Text, View } from 'react-native';
import { ScruterCMP, useConsentChoice } from '@scruter/react-native';
import { partners, watchPartners } from '../partners';
import { Button } from '../ui';

function Row({ label, value, testID }: { label: string; value: string; testID: string }) {
  return (
    <View style={{ flexDirection: 'row', justifyContent: 'space-between', paddingHorizontal: 16, paddingVertical: 10 }}>
      <Text>{label}</Text>
      <Text testID={testID} style={{ color: '#4D4859' }}>
        {value}
      </Text>
    </View>
  );
}

/** The CMP's screen of the example: the state, the receipt, the stand-ins gated on the answer, the settings entry. */
export function Privacy() {
  const choice = useConsentChoice();
  const [p, setP] = React.useState(partners());
  React.useEffect(() => watchPartners(setP), []);
  const [state, setState] = React.useState(ScruterCMP.state);
  React.useEffect(() => setState(ScruterCMP.state), [choice]);
  return (
    <ScrollView testID="privacy" contentContainerStyle={{ paddingVertical: 8 }}>
      <Text style={{ fontWeight: '600', margin: 16, marginBottom: 4 }}>Scruter CMP</Text>
      <Row label="State" value={state} testID="cmp_state" />
      <Row label="Receipt" value={choice?.consentId ?? '—'} testID="cmp_consent_id" />
      <Row label="whenReady · onChange" value={`${p.ready} · ${p.changes}`} testID="cmp_calls" />
      <Text style={{ fontWeight: '600', margin: 16, marginBottom: 4 }}>Gated on the answer</Text>
      <Row label="Analytics SDK" value={p.analyticsStarted ? 'started' : 'off'} testID="partner_analytics" />
      <Row label="Ads" value={p.personalisedAds ? 'personalised' : 'non-personalised'} testID="partner_ads" />
      <Row label="Attribution" value={p.attributionStarted ? 'started' : 'off'} testID="partner_attribution" />
      <Row label="analytics_storage" value={p.analyticsStorage} testID="partner_gcm" />
      <Row label="Tracking (ATT)" value={p.tracking} testID="partner_att" />
      <Text style={{ fontWeight: '600', margin: 16, marginBottom: 4 }}>Settings</Text>
      {/* The settings entry first (CMP.md): how a visitor changes or withdraws their choice. */}
      <Button testID="privacy_choices" title="Privacy choices" onPress={() => ScruterCMP.showPreferences()} />
      <Button testID="cmp_reset" title="Reset the choice (debug)" onPress={() => ScruterCMP.debugReset()} />
      <Button testID="cmp_reload" title="Reload JavaScript (test)" onPress={() => DevSettings.reload('reload test')} />
    </ScrollView>
  );
}
