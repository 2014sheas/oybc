import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import {
  appendTypedChild,
  buildNewChildTask,
  canAppendCounting,
  childPatchFromTask,
  newChildPatch,
  validatePatch,
  type TaskEditPatch,
} from '../taskEditPatch';

const EMPTY: TaskEditPatch = { title: 'Music week', action: '', goal: '', unit: '', children: [] };

describe('ChildPatch countKind', () => {
  it('a new counting child starts discrete', () => {
    expect(newChildPatch(true).countKind).toBe('discrete');
  });
  it('an existing child seeds its kind and goal text', () => {
    const child = { id: 'c', title: 'Run 26.2 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' } as Task;
    const patch = childPatchFromTask(child);
    expect(patch.countKind).toBe('continuous');
    expect(patch.goal).toBe('26.2');
  });
  it('canAppendCounting is kind-aware', () => {
    expect(canAppendCounting('Run', '3.1', 'mi', 'continuous')).toBe(true);
    expect(canAppendCounting('Run', '3.1', 'mi', 'discrete')).toBe(false);
    expect(canAppendCounting('Practice', '1h 30m', '', 'duration')).toBe(true);
    expect(canAppendCounting('Practice', '90', '', 'discrete')).toBe(false);
  });
  it('a Duration child validates without a unit; a continuous child refuses 3 places', () => {
    const dur = appendTypedChild(EMPTY, 'Practice', true, '1h 30m', '', 'duration');
    expect(validatePatch(dur, TaskType.COMPOUND)).toBeNull();
    const bad = { ...EMPTY, children: [{ ...newChildPatch(true), title: 'Run', action: 'Run', goal: '3.125', unit: 'mi', countKind: 'continuous' as const }] };
    expect(validatePatch(bad, TaskType.COMPOUND)).toBe('Counting sub-task "Run" needs a goal and a unit.');
  });
  it('appendTypedChild titles a Duration sub-task without a unit', () => {
    const next = appendTypedChild(EMPTY, 'Practice', true, '1h 30m', '', 'duration');
    expect(next.children[0]).toMatchObject({ title: 'Practice 1h 30m', countKind: 'duration', goal: '1h 30m', unit: '' });
  });
  it('a new Duration child persists minutes, no unit and its kind', () => {
    const next = appendTypedChild(EMPTY, 'Practice', true, '1h 30m', 'ignored', 'duration');
    const task = buildNewChildTask('id', next.children[0], 'Practice 1h 30m', 'u', 'now');
    expect(task).toMatchObject({ maxCount: 90, unit: '', countKind: 'duration' });
  });
});
