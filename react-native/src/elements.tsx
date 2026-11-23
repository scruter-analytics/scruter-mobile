import * as React from 'react';
import { View } from 'react-native';
import type { ViewProps } from 'react-native';

export interface ScruterMarks {
  /** The element's stable name in Screen analysis, when `testID` is taken or absent. */
  scruterId?: string;
  /** The fields inside form this form ("Delivery"). */
  scruterForm?: string;
  /** No tap, no field, nothing in the team phones' element tree. */
  scruterIgnore?: boolean;
  /** An opaque rectangle in the team phones' screen images. */
  scruterMask?: boolean;
}

/**
 * The marks travel in the view's `nativeID`, the one string every architecture keeps on the host view and reads again
 * at each walk: Fabric recycles its views, so a mark set on a view object would stay on the view's next user.
 */
export function encodeMarks(marks: ScruterMarks, index?: number): string | undefined {
  const parts: string[] = [];
  if (marks.scruterMask) parts.push('m');
  if (marks.scruterIgnore) parts.push('g');
  if (marks.scruterId) parts.push(`i=${encodeURIComponent(marks.scruterId)}`);
  if (marks.scruterForm) parts.push(`f=${encodeURIComponent(marks.scruterForm)}`);
  if (index !== undefined) parts.push(`c=${index}`);
  return parts.length ? `scruter:${parts.join(';')}` : undefined;
}

export type ScruterViewProps = ViewProps & ScruterMarks;

/** A `View` that carries Scruter's marks. `collapsable={false}`: it stays a host view on every architecture. */
export const ScruterView = React.forwardRef<View, ScruterViewProps & { index?: number }>(function ScruterView(
  { scruterId, scruterForm, scruterIgnore, scruterMask, index, nativeID, ...rest },
  ref,
) {
  const marks = encodeMarks({ scruterId, scruterForm, scruterIgnore, scruterMask }, index);
  return <View ref={ref} collapsable={false} {...rest} nativeID={marks ?? nativeID} />;
});

/** Everything inside is covered in the team phones' screen images (docs/MOBILE.md §3.11). Users are never captured. */
export const ScruterMask = React.forwardRef<View, Omit<ScruterViewProps, 'scruterMask'>>(function ScruterMask(props, ref) {
  return <ScruterView ref={ref} {...props} scruterMask />;
});

type CellProps = ViewProps & { index: number; item?: unknown; cellKey?: string; children?: React.ReactNode };

/**
 * `<FlatList CellRendererComponent={ScruterCell} …>`: the list's exact item position for each cell, where variable
 * heights make the automatic one approximate (docs/MOBILE.md §20).
 */
export function ScruterCell({ index, item: _item, cellKey: _key, ...rest }: CellProps) {
  return <ScruterView {...rest} index={index} />;
}
