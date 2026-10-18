import * as fs from 'fs';
import * as path from 'path';
import {
  goalChipAmounts, hubChips, lateLogChipAmounts,
  logPillLabel, logPillOpensDetail, quickLogAmount, tapLogChips,
} from '../../src/algorithms/logAmounts';
import * as barrel from '../../src/algorithms';
import type { CountKind } from '../../src/algorithms/countValue';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const V: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/logAmountVectors.json'), 'utf8'));

describe('logAmounts vectors', () => {
  it.each(V.goalChips as any[])('goalChips: $name', (v: any) => expect(goalChipAmounts(v.goal, v.kind as CountKind)).toEqual(v.expected));
  it.each(V.hubChipLabels as any[])('hubChips: $name', (v: any) => expect(hubChips(v.kind).map((c) => c.label)).toEqual(v.expected));
  it.each(V.lateLogChips as any[])('lateLogChips: $name', (v: any) => expect(lateLogChipAmounts(v.kind, v.goal)).toEqual(v.expected));
  it.each(V.quickAmount as any[])('quickAmount: $name', (v: any) =>
    expect(quickLogAmount(v.kind, hubChips(v.kind), v.default)).toBe(v.expected));
  it.each(V.pill as any[])('pill: $name', (v: any) => {
    expect(logPillLabel(v.kind, v.default)).toBe(v.label);
    expect(logPillOpensDetail(v.kind, v.default)).toBe(v.opensDetail);
  });
  it.each(V.tapChips as any[])('tapChips: $name', (v: any) => {
    const chips = tapLogChips(v.kind, v.goal, v.count);
    expect(chips.map((c) => c.label)).toEqual(v.expected);
    if (v.values) expect(chips.map((c) => c.value)).toEqual(v.values);
    if (v.roles) expect(chips.map((c) => c.role)).toEqual(v.roles);
  });
  it('every helper is in the barrel (Ruling U2)', () => {
    for (const n of ['goalChipAmounts', 'hubChips', 'lateLogChipAmounts', 'logPillLabel', 'logPillOpensDetail', 'quickLogAmount', 'fixedLogChipAmounts', 'tapLogChips']) {
      expect(typeof (barrel as Record<string, unknown>)[n]).toBe('function');
    }
  });
});
