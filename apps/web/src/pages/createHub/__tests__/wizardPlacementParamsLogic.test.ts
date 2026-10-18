import { describe, expect, it } from 'vitest';
import type { PlacementParams } from '@oybc/shared';
import {
  freezeTypedManualTargets,
  initialPlacementParamsSeed,
  placementParamsFromManualTargets,
  withTypedPlacementFor,
  withoutTypedPlacement,
} from '../wizardPlacementParamsLogic';

describe('wizardPlacementParamsLogic — typed provenance + frozen-goal hydration', () => {
  const frozen = { a: { target: 12, kind: 'discrete' as const, title: 'Twelve' }, b: { target: 2.5, kind: 'continuous' as const } };

  it('placementParamsFromManualTargets maps target/kind/title to the placement fields', () => {
    expect(placementParamsFromManualTargets(frozen)).toEqual({
      a: { targetOverride: 12, targetKind: 'discrete', titleOverride: 'Twelve' },
      b: { targetOverride: 2.5, targetKind: 'continuous' },
    });
    expect(placementParamsFromManualTargets(undefined)).toEqual({});
  });

  it('a draft blob wins over the record; the record seeds every frozen goal as typed', () => {
    const blob = { placementParams: { z: { targetOverride: 3 } as PlacementParams }, typedPlacementIds: [] };
    expect(initialPlacementParamsSeed(blob, frozen)).toEqual({ params: blob.placementParams, typedIds: [] });
    const fromRecord = initialPlacementParamsSeed(null, frozen);
    expect(fromRecord.typedIds).toEqual(['a', 'b']);
    expect(initialPlacementParamsSeed(null, undefined)).toEqual({ params: {}, typedIds: [] });
  });

  it('hydrate then freeze is the identity on a record\'s frozen goals', () => {
    const { params, typedIds } = initialPlacementParamsSeed(null, frozen);
    expect(freezeTypedManualTargets(['a', 'b'], new Map(Object.entries(params)), new Set(typedIds))).toEqual(frozen);
  });

  it('freezeTypedManualTargets skips untyped entries, non-members and goal-less entries', () => {
    const params = new Map<string, PlacementParams>([
      ['typed', { targetOverride: 9, targetKind: 'discrete' }],
      ['auto', { targetOverride: 5, targetKind: 'discrete' }],
      ['outsider', { targetOverride: 4 }],
      ['titleOnly', { titleOverride: 'x' }],
    ]);
    expect(
      freezeTypedManualTargets(['typed', 'auto', 'titleOnly'], params, new Set(['typed', 'outsider', 'titleOnly'])),
    ).toEqual({ typed: { target: 9, kind: 'discrete' } });
  });

  it('typed-set transitions return the same set when nothing changes', () => {
    const s: ReadonlySet<string> = new Set(['a']);
    expect(withTypedPlacementFor(s, 'a', true)).toBe(s);
    expect(withTypedPlacementFor(s, 'b', false)).toBe(s);
    expect([...withTypedPlacementFor(s, 'b', true)]).toEqual(['a', 'b']);
    expect([...withTypedPlacementFor(s, 'a', false)]).toEqual([]);
    expect(withoutTypedPlacement(s, ['x'])).toBe(s);
    expect([...withoutTypedPlacement(s, ['a', 'x'])]).toEqual([]);
  });
});
