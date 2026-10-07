import * as fs from 'fs';
import * as path from 'path';
import {
  quantizeCount, isQuantizedCount, finalizeWindowCount, formatCount, formatCountForInput,
  planCountKindSwitch, canSwitchCountKind, resolveCountKind, isWholeCountKind,
  countTargetStep, ceilToCountStep, roundToCountStep, floorToCountStep, type CountKind,
} from '../../src/algorithms/countValue';

interface CountValueFixture {
  quantize: Array<{ name: string; x: number; expected: number }>;
  isQuantized: Array<{ name: string; x: number; expected: boolean }>;
  finalize: Array<{ name: string; sum: number; kind: string; expected: number }>;
  format: Array<{ name: string; value: number; kind: string; locale: string; expected: string }>;
  formatForInput: Array<{ name: string; value: number; kind: string; expected: string }>;
  switch: Array<{ name: string; from: string; to: string; fields: { maxCount?: number | null; defaultLogAmount?: number | null }; expected: { maxCount?: number; defaultLogAmount?: number } | null }>;
  ceilToStep: Array<{ name: string; x: number; kind: string; expected: number }>;
  roundToStep: Array<{ name: string; x: number; kind: string; expected: number }>;
  floorToStep: Array<{ name: string; x: number; kind: string; expected: number }>;
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/countValueVectors.json');
const vectors: CountValueFixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

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
  it.each(vectors.formatForInput)('formatForInput: $name', ({ value, kind, expected }) => {
    expect(formatCountForInput(value, kind as CountKind)).toBe(expected);
  });
  it.each(vectors.switch)('switch: $name', ({ from, to, fields, expected }) => {
    expect(planCountKindSwitch(fields, from as CountKind, to as CountKind)).toEqual(expected);
  });
  it.each(vectors.ceilToStep)('ceilToStep: $name', ({ x, kind, expected }) => {
    expect(ceilToCountStep(x, kind as CountKind)).toBe(expected);
  });
  it.each(vectors.roundToStep)('roundToStep: $name', ({ x, kind, expected }) => {
    expect(roundToCountStep(x, kind as CountKind)).toBe(expected);
  });
  it.each(vectors.floorToStep)('floorToStep: $name', ({ x, kind, expected }) => {
    expect(floorToCountStep(x, kind as CountKind)).toBe(expected);
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
