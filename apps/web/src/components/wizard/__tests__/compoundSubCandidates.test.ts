import { describe, expect, it } from 'vitest';
import { TaskType, Timeframe, type Task } from '@oybc/shared';
import { appendCounterChild, compoundSubCandidates, countersInDraft } from '../compoundSubCandidates';
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

  it('a counter already a sub-task of THIS compound is not offered again', () => {
    const withHub = appendCounterChild(emptyPatch("C"), hubWithGoal);
    const after = compoundSubCandidates('P', library, [...library, copy], [], withHub);
    expect(after.counterIds.has('hubGoal')).toBe(false);
    expect(after.candidates.map((t) => t.id)).not.toContain('hubGoal');
    // A saved child linked to the counter (its task carries the link) counts too.
    const savedCopy = task('saved', { sharedCounterId: 'hub' });
    const saved = { ...emptyPatch('C'), children: [{ ...withHub.children[0], id: 'saved', childTaskId: 'saved', sharedCounterId: undefined }] };
    expect([...countersInDraft(saved, [...library, savedCopy])]).toEqual(['saved', 'hub']);
    // A deleted child frees it.
    const deleted = { ...withHub, children: [{ ...withHub.children[0], markedDeleted: true }] };
    expect(countersInDraft(deleted, library).size).toBe(0);
  });
});

describe('appendCounterChild', () => {
  it('one pick appends a complete linked Counting sub-task, goal at the window default', () => {
    const root = task('r', { isCounter: true, maxCount: undefined, currentCount: 9, timeframeGoals: { weekly: 3 } });
    const next = appendCounterChild(emptyPatch('C'), root, { timeframe: Timeframe.WEEKLY });
    expect(next.children).toHaveLength(1);
    expect(next.children[0]).toMatchObject({
      isCounting: true, action: 'Read', unit: 'books', goal: '3', title: 'Read 3 books', sharedCounterId: 'r', baseline: 9,
    });
    // No window: the yearly default (derived from the weekly one).
    expect(appendCounterChild(emptyPatch('C'), root).children[0].goal).toBe('157');
  });
});
