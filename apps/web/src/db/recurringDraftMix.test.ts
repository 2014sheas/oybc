import { describe, expect, it } from 'vitest';
import { decodeRecurringDraftMix, encodeRecurringDraftMix } from './recurringDraftMix';
import type { BoardSource } from '@oybc/shared';

const EMPTY = {
  poolIds: [],
  manualTaskIds: [],
  removedTaskIds: [],
  sources: [],
  manualTaskVary: {},
};

/** The [0, all] pool source the codec derives for a trio-only input. */
const derivedSource = (poolId: string, removedTaskIds: string[]): BoardSource => ({
  sourceId: poolId,
  kind: 'pool',
  min: 0,
  max: null,
  excludedTaskIds: removedTaskIds,
  filter: 'all',
});

describe('encodeRecurringDraftMix / decodeRecurringDraftMix', () => {
  it('round-trips a populated mix, deriving [0, all] sources for the trio', () => {
    const mix = {
      poolIds: ['pool-1', 'pool-2'],
      manualTaskIds: ['manual-1'],
      removedTaskIds: ['removed-1'],
    };
    const encoded = encodeRecurringDraftMix(mix);
    expect(typeof encoded).toBe('string');
    expect(decodeRecurringDraftMix(encoded)).toEqual({
      ...mix,
      sources: [
        derivedSource('pool-1', ['removed-1']),
        derivedSource('pool-2', ['removed-1']),
      ],
      manualTaskVary: {},
    });
  });

  it('round-trips an explicit sources array verbatim (v2 canonical)', () => {
    const sources: BoardSource[] = [
      {
        sourceId: 'board-9',
        kind: 'board',
        min: 1,
        max: 3,
        excludedTaskIds: ['x'],
        filter: 'todo',
      },
    ];
    const mix = {
      poolIds: [],
      manualTaskIds: ['manual-1'],
      removedTaskIds: [],
      sources,
      manualTaskVary: {},
    };
    expect(decodeRecurringDraftMix(encodeRecurringDraftMix(mix))).toEqual(mix);
  });

  it('decodes a v1 blob (no sources field) by deriving from the trio', () => {
    const v1 = JSON.stringify({
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: ['gone'],
    });
    expect(decodeRecurringDraftMix(v1)).toEqual({
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: ['gone'],
      sources: [derivedSource('pool-1', ['gone'])],
      manualTaskVary: {},
    });
  });

  it('round-trips an all-empty mix', () => {
    const mix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    expect(decodeRecurringDraftMix(encodeRecurringDraftMix(mix))).toEqual(EMPTY);
  });

  it('decodes `undefined` (a legacy one-off draft, no mix ever written) to an all-empty mix', () => {
    expect(decodeRecurringDraftMix(undefined)).toEqual(EMPTY);
  });

  it('decodes an empty string to an all-empty mix', () => {
    expect(decodeRecurringDraftMix('')).toEqual(EMPTY);
  });

  it('decodes malformed JSON to an all-empty mix rather than throwing', () => {
    expect(decodeRecurringDraftMix('not json{{{')).toEqual(EMPTY);
  });

  it('decodes well-formed JSON with the wrong shape to an all-empty mix', () => {
    expect(decodeRecurringDraftMix(JSON.stringify({ foo: 'bar' }))).toEqual(EMPTY);
    // Wrong element types inside an otherwise-array-shaped field.
    expect(
      decodeRecurringDraftMix(
        JSON.stringify({ poolIds: [1, 2], manualTaskIds: [], removedTaskIds: [] }),
      ),
    ).toEqual(EMPTY);
    // A JSON primitive (not an object at all).
    expect(decodeRecurringDraftMix('"just a string"')).toEqual(EMPTY);
    expect(decodeRecurringDraftMix('null')).toEqual(EMPTY);
  });

  it('a corrupt sources value falls back to deriving from the trio', () => {
    const blob = JSON.stringify({
      v: 2,
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: [],
      sources: [{ nonsense: true }],
    });
    expect(decodeRecurringDraftMix(blob)).toEqual({
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: [],
      sources: [derivedSource('pool-1', [])],
      manualTaskVary: {},
    });
  });
});

describe('manualTaskVary (additive, v stays 2)', () => {
  it('decodes a v2 blob without manualTaskVary to {}', () => {
    const p = decodeRecurringDraftMix(
      JSON.stringify({ v: 2, poolIds: [], manualTaskIds: ['t1'], removedTaskIds: [], sources: [] }),
    );
    expect(p.manualTaskVary).toEqual({});
  });

  it('round-trips manualTaskVary and keeps v: 2', () => {
    const json = encodeRecurringDraftMix({
      poolIds: [],
      manualTaskIds: ['t1'],
      removedTaskIds: [],
      sources: [],
      manualTaskVary: { t1: 2 },
    });
    expect(JSON.parse(json).v).toBe(2);
    expect(decodeRecurringDraftMix(json).manualTaskVary).toEqual({ t1: 2 });
  });

  it('omits the key when empty so an existing blob encodes byte-identically', () => {
    const json = encodeRecurringDraftMix({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
      sources: [],
    });
    expect('manualTaskVary' in JSON.parse(json)).toBe(false);
  });

  it('drops invalid levels on decode (corrupt blob → {} for that key, others kept)', () => {
    const p = decodeRecurringDraftMix(
      JSON.stringify({
        v: 2,
        poolIds: [],
        manualTaskIds: ['t1', 't2'],
        removedTaskIds: [],
        sources: [],
        manualTaskVary: { t1: 7, t2: 1 },
      }),
    );
    expect(p.manualTaskVary).toEqual({ t2: 1 });
  });

  it('a source carrying memberRules passes the shape check and round-trips verbatim', () => {
    const s = {
      sourceId: 's1',
      kind: 'board',
      min: 0,
      max: null,
      excludedTaskIds: [],
      filter: 'all',
      memberRules: { t1: { target: 3, vary: 1 } },
    };
    const p = decodeRecurringDraftMix(
      JSON.stringify({ v: 2, poolIds: [], manualTaskIds: [], removedTaskIds: [], sources: [s] }),
    );
    expect(p.sources[0]).toEqual(s);
  });
});
