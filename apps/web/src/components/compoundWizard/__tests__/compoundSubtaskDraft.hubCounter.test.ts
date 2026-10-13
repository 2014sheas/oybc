import { describe, expect, it } from 'vitest';
import { TaskType, Timeframe, type Task } from '@oybc/shared';
import {
  effectiveInlineKind,
  inlineLinkMatch,
  inlineSubtaskFromCounter,
  inlineSubtaskToAutoCreate,
} from '../compoundSubtaskDraft';

/** A hub counter: no goal of its own, a lifetime count, optional templates. */
const hub = (o: Partial<Task> = {}): Task =>
  ({
    id: 'hub', userId: 'u', title: 'Read pages', type: TaskType.COUNTING, action: 'Read', unit: 'pages', isCounter: true,
    currentCount: 40, isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: 'x', updatedAt: 'x',
    version: 1, isDeleted: false, ...o,
  }) as Task;

describe('compound create — a picked hub counter becomes a linked Counting sub-task', () => {
  it('the draft carries the counter verb, noun and kind, pinned, the goal pre-filled with its default', () => {
    // No window reads as Indefinite → the yearly kind fallback.
    expect(inlineSubtaskFromCounter(hub(), 'd')).toMatchObject({
      inlineType: 'counting', action: 'Read', unit: 'pages', maxCountStr: '365', pinnedCounterId: 'hub',
    });
    expect(inlineSubtaskFromCounter(hub({ timeframeGoals: { weekly: 20 } }), 'd', { timeframe: Timeframe.WEEKLY }).maxCountStr).toBe('20');
    expect(inlineSubtaskFromCounter(hub({ maxCount: 12 }), 'd').maxCountStr).toBe('12');
    const dur = inlineSubtaskFromCounter(hub({ action: 'Practice', unit: undefined, countKind: 'duration' }), 'd');
    expect(dur).toMatchObject({ unit: '', countKind: 'duration', pinnedCounterId: 'hub' });
  });

  it('saves linked to the counter, counting from its lifetime, titled through its templates', () => {
    const root = hub({ titleTemplatePlural: 'Read #N pages!' });
    const draft = { ...inlineSubtaskFromCounter(root, 'd'), maxCountStr: '20' };
    expect(inlineSubtaskToAutoCreate(draft, [root]).autoCreate).toMatchObject({
      type: TaskType.COUNTING, title: 'Read 20 pages!', action: 'Read', unit: 'pages', maxCount: 20,
      sharedCounterId: 'hub', baseline: 40,
    });
  });

  it('a Duration counter links too (the verb+noun matcher never would)', () => {
    const root = hub({ action: 'Practice', unit: undefined, countKind: 'duration' });
    const draft = { ...inlineSubtaskFromCounter(root, 'd'), maxCountStr: '30m' };
    expect(inlineLinkMatch(draft, [root])?.counterId).toBe('hub');
    expect(effectiveInlineKind(draft, [root])).toBe('duration');
    expect(inlineSubtaskToAutoCreate(draft, [root]).autoCreate).toMatchObject({ sharedCounterId: 'hub', maxCount: 30 });
  });

  it('editing the verb unpins it; "Don\'t link" opts out', () => {
    const root = hub({ action: 'Practice', unit: undefined, countKind: 'duration' });
    const draft = { ...inlineSubtaskFromCounter(root, 'd'), maxCountStr: '30m' };
    expect(inlineLinkMatch({ ...draft, action: 'Play' }, [root])).toBeNull();
    expect(inlineSubtaskToAutoCreate({ ...draft, linkDisabled: true }, [root]).autoCreate?.sharedCounterId).toBeUndefined();
  });
});
