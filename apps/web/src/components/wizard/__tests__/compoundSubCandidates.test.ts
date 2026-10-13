import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { compoundSubCandidates } from '../compoundSubCandidates';
import { emptyPatch } from '../../../db/taskEditPatch';

const T0 = '2026-10-01T00:00:00.000Z';
const task = (id: string, over: Partial<Task> = {}): Task =>
  ({
    id, userId: 'u1', title: id, type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 5,
    isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

describe('compoundSubCandidates', () => {
  const hubNoGoal = task('hub', { isCounter: true, maxCount: undefined });
  const hubWithGoal = task('hubGoal', { isCounter: true, maxCount: 12 });
  const defaults = task('defaults', { timeframeGoals: { weekly: 2 } });
  const linkedTo = task('linkedTo');
  const copy = task('copy', { sharedCounterId: 'linkedTo' });
  const plain = task('plain');
  const normal = task('normal', { type: TaskType.NORMAL, action: undefined, unit: undefined, maxCount: undefined });
  const library = [hubNoGoal, hubWithGoal, defaults, linkedTo, plain, normal];

  it('every counter root — goal-less, with a goal, with defaults, linked-to — is a counter pick', () => {
    const { candidates, counterIds } = compoundSubCandidates('P', library, [...library, copy], [], emptyPatch('C'));
    expect([...counterIds].sort()).toEqual(['defaults', 'hub', 'hubGoal', 'linkedTo']);
    expect(candidates.map((t) => t.id)).toEqual(['normal', 'plain', 'hub', 'hubGoal', 'defaults', 'linkedTo']);
  });

  it('a compound counting toward a counter never lists it', () => {
    const parent = task('P', { type: TaskType.COMPOUND, countsTowardCounterId: 'hubGoal' });
    const { candidates } = compoundSubCandidates('P', library, [...library, parent], [], emptyPatch('C'));
    expect(candidates.map((t) => t.id)).not.toContain('hubGoal');
  });

  it('a root is found through its linked member in the FULL set only', () => {
    expect(compoundSubCandidates('P', library, library, [], emptyPatch('C')).counterIds.has('linkedTo')).toBe(false);
  });
});
