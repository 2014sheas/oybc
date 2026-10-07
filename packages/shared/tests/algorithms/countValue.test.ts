import vectors from '../fixtures/countValueVectors.json';
import {
  quantizeCount, isQuantizedCount, finalizeWindowCount, formatCount,
  planCountKindSwitch, canSwitchCountKind, resolveCountKind, isWholeCountKind,
  countTargetStep, type CountKind,
} from '../../src/algorithms/countValue';

describe('countValue vectors', () => {
  it.each(vectors.quantize)('quantize: $name', ({ x, expected }) => {
    expect(quantizeCount(x)).toBe(expected);
  });
  it.each(vectors.isQuantized)('isQuantized: $name', ({ x, expected }) => {
    expect(isQuantizedCount(x)).toBe(expected);
  });
  it.each(vectors.finalize)('finalize: $name', ({ sum, kind, expected }) => {
    expect(finalizeWindowCount(sum, kind as CountKind)).toBe(expected);
  });
  it.each(vectors.format)('format: $name', ({ value, kind, locale, expected }) => {
    expect(formatCount(value, kind as CountKind, locale)).toBe(expected);
  });
  it.each(vectors.switch)('switch: $name', ({ from, to, fields, expected }) => {
    expect(planCountKindSwitch(fields, from as CountKind, to as CountKind)).toEqual(expected);
  });
});

describe('countValue helpers', () => {
  it('absent or null kind resolves to discrete', () => {
    expect(resolveCountKind({})).toBe('discrete');
    expect(resolveCountKind({ countKind: null })).toBe('discrete');
    expect(resolveCountKind({ countKind: 'continuous' })).toBe('continuous');
  });
  it('whole kinds are discrete and duration', () => {
    expect(isWholeCountKind('discrete')).toBe(true);
    expect(isWholeCountKind('duration')).toBe(true);
    expect(isWholeCountKind('continuous')).toBe(false);
  });
  it('rejects non-finite values', () => {
    expect(isQuantizedCount(Number.NaN)).toBe(false);
    expect(isQuantizedCount(Number.POSITIVE_INFINITY)).toBe(false);
  });
  it('switch permission matrix', () => {
    expect(canSwitchCountKind('discrete', 'continuous')).toBe(true);
    expect(canSwitchCountKind('continuous', 'discrete')).toBe(true);
    expect(canSwitchCountKind('discrete', 'duration')).toBe(false);
    expect(canSwitchCountKind('duration', 'discrete')).toBe(false);
    expect(canSwitchCountKind('discrete', 'discrete')).toBe(false);
  });
  it('target step per kind', () => {
    expect(countTargetStep('discrete')).toBe(1);
    expect(countTargetStep('duration')).toBe(1);
    expect(countTargetStep('continuous')).toBe(0.1);
  });
});
