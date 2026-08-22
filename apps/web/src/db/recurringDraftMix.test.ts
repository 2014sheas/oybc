import { describe, expect, it } from 'vitest';
import { decodeRecurringDraftMix, encodeRecurringDraftMix } from './recurringDraftMix';

describe('encodeRecurringDraftMix / decodeRecurringDraftMix', () => {
  it('round-trips a populated mix', () => {
    const mix = {
      poolIds: ['pool-1', 'pool-2'],
      manualTaskIds: ['manual-1'],
      removedTaskIds: ['removed-1'],
    };
    const encoded = encodeRecurringDraftMix(mix);
    expect(typeof encoded).toBe('string');
    expect(decodeRecurringDraftMix(encoded)).toEqual(mix);
  });

  it('round-trips an all-empty mix', () => {
    const mix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    expect(decodeRecurringDraftMix(encodeRecurringDraftMix(mix))).toEqual(mix);
  });

  it('decodes `undefined` (a one-off draft, no mix ever written) to an all-empty mix', () => {
    expect(decodeRecurringDraftMix(undefined)).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
  });

  it('decodes an empty string to an all-empty mix', () => {
    expect(decodeRecurringDraftMix('')).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
  });

  it('decodes malformed JSON to an all-empty mix rather than throwing', () => {
    expect(decodeRecurringDraftMix('not json{{{')).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
  });

  it('decodes well-formed JSON with the wrong shape to an all-empty mix', () => {
    expect(decodeRecurringDraftMix(JSON.stringify({ foo: 'bar' }))).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
    // Wrong element types inside an otherwise-array-shaped field.
    expect(
      decodeRecurringDraftMix(
        JSON.stringify({ poolIds: [1, 2], manualTaskIds: [], removedTaskIds: [] }),
      ),
    ).toEqual({ poolIds: [], manualTaskIds: [], removedTaskIds: [] });
    // A JSON primitive (not an object at all).
    expect(decodeRecurringDraftMix('"just a string"')).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
    expect(decodeRecurringDraftMix('null')).toEqual({
      poolIds: [],
      manualTaskIds: [],
      removedTaskIds: [],
    });
  });
});
