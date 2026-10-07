import * as fs from 'fs';
import * as path from 'path';
import {
  boardSheetChips, customChipLabel, goalChipAmounts, hubChips, initialLogSelection, lateLogChipAmounts,
  logPillLabel, logPillOpensDetail, quickLogAmount,
} from '../../src/algorithms/logAmounts';
import * as barrel from '../../src/algorithms';
import type { CountKind } from '../../src/algorithms/countValue';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const V: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/logAmountVectors.json'), 'utf8'));

describe('logAmounts vectors', () => {
  it.each(V.goalChips as any[])('goalChips: $name', (v: any) => expect(goalChipAmounts(v.goal, v.kind as CountKind)).toEqual(v.expected));
  it.each(V.boardSheetChipLabels as any[])('boardSheetChips: $name', (v: any) =>
    expect(boardSheetChips(v.kind, v.goal).map((c) => c.label)).toEqual(v.expected));
  it.each(V.hubChipLabels as any[])('hubChips: $name', (v: any) => expect(hubChips(v.kind).map((c) => c.label)).toEqual(v.expected));
  it.each(V.lateLogChips as any[])('lateLogChips: $name', (v: any) => expect(lateLogChipAmounts(v.kind, v.goal)).toEqual(v.expected));
  it.each(V.initialSelection as any[])('initialSelection: $name', (v: any) =>
    expect(initialLogSelection(v.kind, boardSheetChips(v.kind, v.goal), v.default)).toEqual(v.expected));
  it.each(V.quickAmount as any[])('quickAmount: $name', (v: any) =>
    expect(quickLogAmount(v.kind, boardSheetChips(v.kind, v.goal), v.default)).toBe(v.expected));
  it.each(V.pill as any[])('pill: $name', (v: any) => {
    expect(logPillLabel(v.kind, v.default)).toBe(v.label);
    expect(logPillOpensDetail(v.kind, v.default)).toBe(v.opensDetail);
  });
  it.each(V.customChipLabel as any[])('customChipLabel: $name', (v: any) =>
    expect(customChipLabel(v.amount, v.kind)).toBe(v.expected));
  it('every helper is in the barrel (Ruling U2)', () => {
    for (const n of ['boardSheetChips', 'goalChipAmounts', 'hubChips', 'initialLogSelection', 'lateLogChipAmounts', 'logPillLabel', 'logPillOpensDetail', 'quickLogAmount', 'customChipLabel', 'fixedLogChipAmounts']) {
      expect(typeof (barrel as Record<string, unknown>)[n]).toBe('function');
    }
  });
});
