import * as React from 'react';
import { create } from 'react-test-renderer';
import { encodeMarks, ScruterCell, ScruterMask, ScruterView } from '../src/elements';

describe('encodeMarks', () => {
  it('writes every mark, values encoded', () => {
    expect(
      encodeMarks({ scruterMask: true, scruterIgnore: true, scruterId: 'add_to_cart', scruterForm: 'Delivery; fast' }, 12),
    ).toBe('scruter:m;g;i=add_to_cart;f=Delivery%3B%20fast;c=12');
  });

  it('writes nothing without a mark', () => {
    expect(encodeMarks({})).toBeUndefined();
  });
});

describe('components', () => {
  const props = (el: React.ReactElement) => create(el).toJSON() as unknown as { props: Record<string, unknown> };

  it('ScruterMask stays a host view and keeps the other props', () => {
    const p = props(<ScruterMask testID="address" style={{ flex: 1 }} />).props;
    expect(p).toMatchObject({ testID: 'address', collapsable: false, nativeID: 'scruter:m', style: { flex: 1 } });
  });

  it('ScruterView leaves an app\'s nativeID alone when it has no mark', () => {
    expect(props(<ScruterView nativeID="mine" />).props.nativeID).toBe('mine');
    expect(props(<ScruterView scruterForm="Delivery" />).props.nativeID).toBe('scruter:f=Delivery');
  });

  it('ScruterCell gives FlatList\'s index and drops its bookkeeping', () => {
    const p = props(<ScruterCell index={7} item={{ a: 1 }} cellKey="k" />).props;
    expect(p.nativeID).toBe('scruter:c=7');
    expect(p.item).toBeUndefined();
    expect(p.cellKey).toBeUndefined();
  });
});
