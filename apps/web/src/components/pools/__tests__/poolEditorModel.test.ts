import { describe, expect, it } from 'vitest';
import { AchievementTrigger, OperatorType, TaskType } from '@oybc/shared';
import type { CompoundChild, Task } from '@oybc/shared';
import { emptyPatch, patchesEqual, type TaskEditPatch } from '../../../db/taskEditPatch';
import {
  buildPoolEditorView,
  canSavePool,
  dropMemberVary,
  dropStagedEdit,
  groupLinksByCompound,
  pruneMemberVaryToMembers,
  pruneStagedEdits,
  seedEditorDraft,
  setMemberVaryLevel,
  stageEditInto,
} from '../poolEditorModel';

const NOW = '2026-10-05T00:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function link(compoundTaskId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id: `${compoundTaskId}-${childTaskId}`,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

describe('buildPoolEditorView', () => {
  it('keeps taskIds order and skips unresolvable ids', () => {
    const view = buildPoolEditorView('u1', ['b', 'ghost', 'a'], [task('a'), task('b')], new Map(), {}, new Map());
    expect(view.poolOrder).toEqual(['b', 'a']);
    expect(view.poolTasks.map((t) => t.id)).toEqual(['b', 'a']);
  });

  it('resolves a just-added task from the session cache before the live query delivers it', () => {
    const fresh = task('fresh', { title: 'Fresh' });
    const view = buildPoolEditorView('u1', ['fresh'], [], new Map([['fresh', fresh]]), {}, new Map());
    expect(view.poolTasks).toEqual([fresh]);
  });

  it('overlays a staged rename without changing order', () => {
    const staged = new Map([['a', emptyPatch('Renamed')]]);
    const view = buildPoolEditorView('u1', ['a', 'b'], [task('a'), task('b')], new Map(), {}, staged);
    expect(view.poolOrder).toEqual(['a', 'b']);
    expect(view.effectiveTaskMap.a.title).toBe('Renamed');
    expect(view.effectiveTaskMap.b.title).toBe('Task b');
  });

  it('overlays a staged compound edit onto the children map', () => {
    const compound = task('c', { type: TaskType.COMPOUND, operator: OperatorType.AND });
    const base = { c: [link('c', 'k1', 0), link('c', 'k2', 1)] };
    const patch: TaskEditPatch = {
      ...emptyPatch('Routine'),
      operator: OperatorType.AND,
      children: [
        {
          id: 'p1',
          title: 'Only one',
          isCounting: false,
          action: '',
          goal: '',
          unit: '',
          childTaskId: 'k1',
          childType: TaskType.NORMAL,
          markedDeleted: false,
        },
      ],
    };
    const view = buildPoolEditorView(
      'u1',
      ['c'],
      [compound, task('k1'), task('k2')],
      new Map(),
      base,
      new Map([['c', patch]]),
    );
    expect(view.effectiveChildrenByCompound.c).toHaveLength(1);
    expect(view.effectiveChildrenByCompound.c[0].childTaskId).toBe('k1');
  });

  it('a legacy achievement member still resolves as a removable row', () => {
    const ach = task('ach', { type: TaskType.ACHIEVEMENT, achievementTrigger: AchievementTrigger.BINGO });
    const view = buildPoolEditorView('u1', ['ach', 'a'], [ach, task('a')], new Map(), {}, new Map());
    expect(view.poolOrder).toEqual(['ach', 'a']);
  });
});

describe('seedEditorDraft', () => {
  it('first open of a Counting task with an auto title seeds a blank title', () => {
    const counting = task('r', { type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5 });
    const draft = seedEditorDraft(counting, new Map(), { r: counting }, {});
    expect(draft.title).toBe('');
    expect(draft.goal).toBe('5');
  });

  it('reopen reuses the staged patch verbatim', () => {
    const t = task('a');
    const staged = new Map([['a', emptyPatch('Staged')]]);
    expect(seedEditorDraft(t, staged, { a: t }, {})).toBe(staged.get('a'));
  });

  it('a compound seeds its sorted children', () => {
    const compound = task('c', { type: TaskType.COMPOUND, operator: OperatorType.OR });
    const map = { c: compound, k1: task('k1'), k2: task('k2') };
    const draft = seedEditorDraft(compound, new Map(), map, {
      c: [link('c', 'k2', 1), link('c', 'k1', 0)],
    });
    expect(draft.children.map((c) => c.childTaskId)).toEqual(['k1', 'k2']);
  });
});

describe('staged edits', () => {
  it('stageEditInto replaces a prior patch for the same task and leaves the input untouched', () => {
    const first = new Map([['a', emptyPatch('One')]]);
    const second = stageEditInto(first, 'a', emptyPatch('Two'));
    expect(second.get('a')?.title).toBe('Two');
    expect(first.get('a')?.title).toBe('One');
  });

  it('discarding a draft leaves the staged map exactly as it was; saving it stages the patch', () => {
    const t = task('a');
    const baseline = seedEditorDraft(t, new Map(), { a: t }, {});
    const typed = { ...baseline, title: 'typed then discarded' };
    expect(patchesEqual(typed, baseline)).toBe(false);
    const before = new Map<string, TaskEditPatch>([['z', emptyPatch('prior')]]);
    // Discard = the editor closes WITHOUT calling stageEditInto: reopening
    // seeds from the (unchanged) map, so the typed draft is gone.
    const reopened = seedEditorDraft(t, before, { a: t }, {});
    expect(patchesEqual(reopened, baseline)).toBe(true);
    expect(before.has('a')).toBe(false);
    // Save is the only path that stages it.
    expect(stageEditInto(before, 'a', typed).get('a')).toBe(typed);
  });

  it('pruneStagedEdits keeps only ids still in the pool AND still resolvable', () => {
    const m = new Map([
      ['kept', emptyPatch('k')],
      ['removed', emptyPatch('r')],
      ['vanished', emptyPatch('v')],
    ]);
    const pruned = pruneStagedEdits(m, ['kept', 'vanished'], new Set(['kept']));
    expect([...pruned.keys()]).toEqual(['kept']);
  });

  it('dropStagedEdit removes a removed row\'s edit and is a no-op when absent', () => {
    const m = new Map([['a', emptyPatch('x')]]);
    expect(dropStagedEdit(m, 'a').size).toBe(0);
    expect(dropStagedEdit(m, 'zzz')).toBe(m);
  });
});

describe('canSavePool', () => {
  it('needs a trimmed name, a resolvable task, and not busy', () => {
    expect(canSavePool('P', 1, false)).toBe(true);
    expect(canSavePool('   ', 1, false)).toBe(false);
    expect(canSavePool('P', 0, false)).toBe(false);
    expect(canSavePool('P', 1, true)).toBe(false);
  });
});

describe('groupLinksByCompound', () => {
  it('groups by parent and sorts by childIndex', () => {
    const g = groupLinksByCompound([link('c', 'b', 1), link('c', 'a', 0), link('d', 'x', 0)]);
    expect(g.c.map((l) => l.childTaskId)).toEqual(['a', 'b']);
    expect(Object.keys(g).sort()).toEqual(['c', 'd']);
  });
});

describe('pool-level default dice (memberVary)', () => {
  it('seeds from the pool map, sets a level, and level 0 removes the key', () => {
    const seed = { a: 2 as const };
    const set = setMemberVaryLevel(seed, 'b', 1);
    expect(set).toEqual({ a: 2, b: 1 });
    expect(seed).toEqual({ a: 2 });
    expect(setMemberVaryLevel(set, 'a', 0)).toEqual({ b: 1 });
  });

  it('removing a row drops its entry (and is identity when absent)', () => {
    const m = { a: 1 as const, b: 2 as const };
    expect(dropMemberVary(m, 'a')).toEqual({ b: 2 });
    expect(dropMemberVary(m, 'zzz')).toBe(m);
  });

  it('Save keeps only the dice of current members — iOS save() parity', () => {
    const m = { a: 1 as const, gone: 2 as const };
    expect(pruneMemberVaryToMembers(m, ['a', 'b'])).toEqual({ a: 1 });
    expect(pruneMemberVaryToMembers(m, [])).toEqual({});
    expect(m).toEqual({ a: 1, gone: 2 });
  });
});
