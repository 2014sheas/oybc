import * as fs from 'fs';
import * as path from 'path';
import {
  COUNT_KIND_LABELS,
  countKindNeedsUnit,
  countUnitSuffix,
  durationFromFields,
  durationToFields,
  formatCountWithUnit,
  isKindSegmentLocked,
  kindPickerLock,
  kindSegmentShowsLock,
  parseCountInput,
  resolveFamilyCountKind,
  type KindPickerLock,
} from '../../src/algorithms/countEntry';
import type { CountKind } from '../../src/algorithms/countValue';
import * as barrel from '../../src/algorithms';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const vectors: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/countEntryVectors.json'), 'utf8'));

describe('barrel (Ruling U2)', () => {
  it('re-exports every helper a web surface imports from @oybc/shared', () => {
    for (const name of ['parseCountInput', 'kindPickerLock', 'isKindSegmentLocked', 'kindSegmentShowsLock', 'COUNT_KIND_LABELS',
      'durationToFields', 'durationFromFields', 'countUnitSuffix', 'formatCountWithUnit', 'resolveFamilyCountKind',
      'countKindNeedsUnit', 'formatCountForInput', 'formatCountTotal', 'formatCountRange']) {
      expect(typeof (barrel as Record<string, unknown>)[name]).not.toBe('undefined');
    }
  });
});

describe('countEntry vectors', () => {
  it.each(vectors.parse as any[])('parse: $name', ({ raw, kind, allowZero, expected }) => {
    expect(parseCountInput(raw, kind as CountKind, { allowZero: allowZero === true })).toBe(expected);
  });
  it.each(vectors.durationToFields as any[])('durationToFields: $name', ({ minutes, expected }) => {
    expect(durationToFields(minutes)).toEqual(expected);
  });
  it.each(vectors.durationFromFields as any[])('durationFromFields: $name', ({ hours, minutes, expected }) => {
    expect(durationFromFields(hours, minutes)).toBe(expected);
  });
  it.each(vectors.unitSuffix as any[])('unitSuffix: $name', ({ kind, unit, expected }) => {
    expect(countUnitSuffix(kind as CountKind, unit)).toBe(expected);
  });
  it.each(vectors.pickerLock as any[])('pickerLock: $name', ({ mode, kind, expected }) => {
    expect(kindPickerLock(mode as 'create' | 'edit', kind as CountKind)).toBe(expected);
  });
  it.each(vectors.segmentState as any[])('segmentState: $name', ({ lock, segment, selected, locked, glyph }) => {
    expect(isKindSegmentLocked(lock as KindPickerLock, segment as CountKind)).toBe(locked);
    expect(kindSegmentShowsLock(lock as KindPickerLock, segment as CountKind, selected as CountKind)).toBe(glyph);
  });
});

describe('countEntry helpers', () => {
  it('labels in picker order', () => {
    expect(Object.values(COUNT_KIND_LABELS)).toEqual(['Discrete', 'Continuous', 'Duration']);
  });
  it('only duration drops the unit', () => {
    expect(countKindNeedsUnit('discrete')).toBe(true);
    expect(countKindNeedsUnit('continuous')).toBe(true);
    expect(countKindNeedsUnit('duration')).toBe(false);
  });
  it('formats with the unit suffix', () => {
    expect(formatCountWithUnit(3.1, 'continuous', 'mi', 'en-US')).toBe('3.1 mi');
    expect(formatCountWithUnit(90, 'duration', 'guitar', 'en-US')).toBe('1h 30m');
  });
  it('a linked row takes its root kind; a lost root falls back to its own', () => {
    const root = { countKind: 'continuous' as CountKind };
    const lookup = (id: string) => (id === 'root' ? root : undefined);
    expect(resolveFamilyCountKind({ sharedCounterId: 'root' }, lookup)).toBe('continuous');
    expect(resolveFamilyCountKind({ sharedCounterId: 'gone', countKind: 'discrete' }, lookup)).toBe('discrete');
    expect(resolveFamilyCountKind({ countKind: 'duration' }, lookup)).toBe('duration');
  });
});
