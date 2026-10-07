import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import {
  buildLinkedCreateInput,
  countingGoalError,
  countingTitlePreview,
  effectiveCountingKind,
} from '../createFormCounting';
import { validateForm } from '../useCreateFormState';

const ROOT = {
  id: 'root', userId: 'u1', title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
  maxCount: 26.2, countKind: 'continuous', currentCount: 148.6, isCompleted: false, totalCompletions: 0,
  totalInstances: 0, createdAt: 't', updatedAt: 't', version: 1, isDeleted: false,
} as Task;

describe('createFormCounting', () => {
  it('an auto-linking create takes the root kind; opting out restores the picker', () => {
    expect(effectiveCountingKind('discrete', { linked: true, countKind: 'continuous' })).toBe('continuous');
    expect(effectiveCountingKind('discrete', { linked: false, countKind: 'continuous' })).toBe('discrete');
    expect(effectiveCountingKind('duration', null)).toBe('duration');
  });
  it('goal errors per kind', () => {
    expect(countingGoalError('26.2', 'continuous')).toBeUndefined();
    expect(countingGoalError('3.125', 'continuous')).toBe('Goal must be a number above zero with up to 2 decimals');
    expect(countingGoalError('2.5', 'discrete')).toBe('Goal must be a positive integer');
    expect(countingGoalError('1.5h', 'duration')).toBe('Goal must be a duration above zero');
    expect(countingGoalError('', 'continuous')).toBe('Goal is required');
  });
  it('title preview: duration has no unit; continuous keeps decimals', () => {
    expect(countingTitlePreview('Practice', '10h 30m', '', 'duration')).toBe('Practice 10h 30m');
    expect(countingTitlePreview('Run', '26,2', 'miles', 'continuous')).toBe('Run 26.2 miles');
    expect(countingTitlePreview('Run', '26.2', '', 'continuous')).toBeNull();
  });
  it('linked create takes the root kind: a 6.2 goal typed while the picker said Discrete still saves', () => {
    const input = buildLinkedCreateInput({ source: ROOT, goalText: '6.2', title: '', action: 'Run', unit: 'miles', baseline: 148.6 });
    expect(input).toEqual({ source: ROOT, maxCount: 6.2, title: 'Run 6.2 miles', baselineMode: 'startFromZero', baseline: 148.6 });
  });
  it('a linked create with a goal invalid at the root kind is refused', () => {
    expect(buildLinkedCreateInput({ source: { ...ROOT, countKind: undefined }, goalText: '6.2', title: '', action: 'Run', unit: 'miles', baseline: 0 })).toBeNull();
  });
});

describe('validateForm — counter kinds', () => {
  const v = (action: string, unit: string, goal: string, kind: 'discrete' | 'continuous' | 'duration') =>
    validateForm(TaskType.COUNTING, '', '', action, unit, goal, undefined, undefined, undefined, kind);
  it('duration needs no unit', () => {
    const e = v('Practice', '', '10h 30m', 'duration');
    expect(e.unit).toBeUndefined();
    expect(e.maxCount).toBeUndefined();
  });
  it('continuous still needs the unit and takes a decimal goal', () => {
    expect(v('Run', '', '26.2', 'continuous').unit).toBe('Counting is required');
    expect(v('Run', 'miles', '26.2', 'continuous').maxCount).toBeUndefined();
  });
  it('discrete is unchanged', () => {
    expect(v('Read', 'pages', '2.5', 'discrete').maxCount).toBe('Goal must be a positive integer');
  });
});
