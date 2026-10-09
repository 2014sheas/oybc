import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildSheetOverride, parseGoal, seedSheetTitle, sheetValidationProblem, type SheetInput } from '../boardEditTaskSheetModel';

const original = { id: 't', type: TaskType.COUNTING, title: 'Run 26.2 mi', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' } as Task;
const input = (o: Partial<SheetInput>): SheetInput => ({
  original, selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '26.2', unit: 'mi', countKind: 'continuous',
  compoundDraft: null, compoundBaseline: null, ...o,
});

describe('Board Edit sheet — counter kinds', () => {
  it('parses the goal at the sheet kind', () => {
    expect(parseGoal('26.2', 'continuous')).toBe(26.2);
    expect(parseGoal('26.2', 'discrete')).toBeNull();
    expect(parseGoal('1h 30m', 'duration')).toBe(90);
  });
  it('a staged switch rides on the override with the goal parsed at the new kind', () => {
    expect(buildSheetOverride(input({ countKind: 'discrete', goalStr: '26' }))).toMatchObject({ countKind: 'discrete', maxCount: 26, title: 'Run 26 mi' });
  });
  it('duration validates without a unit; discrete refuses a decimal', () => {
    expect(sheetValidationProblem(input({ countKind: 'duration', goalStr: '1h', unit: '' }))).toBeNull();
    expect(sheetValidationProblem(input({ countKind: 'discrete', goalStr: '26.2' }))).toBe('Set a goal above zero.');
  });
  it('a duration override keeps the row\'s own (hidden) unit and titles in hours and minutes', () => {
    const o = buildSheetOverride(input({ countKind: 'duration', action: 'Practice', goalStr: '1h 30m', unit: 'mi' }));
    expect(o).toMatchObject({ countKind: 'duration', maxCount: 90, unit: 'mi', title: 'Practice 1h 30m' });
  });
  it('switching a counting task to Simple leaves its kind alone (never cleared)', () => {
    const o = buildSheetOverride(input({ selected: TaskType.NORMAL, title: 'Run' }));
    expect('countKind' in o).toBe(false);
  });
  it('an auto Duration title seeds blank', () => {
    expect(seedSheetTitle({ ...original, title: 'Practice 1h 30m', action: 'Practice', unit: '', maxCount: 90, countKind: 'duration' })).toBe('');
  });
});
