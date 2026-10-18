import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType, type Task } from '@oybc/shared';
import { splitBoardEditOverride } from '../boardEditPlacementSplit';
import type { ChildPatch, TaskEditPatch } from '../taskEditPatch';
import { patchHasNonParameterFields } from '../../components/boardEdit/boardScopedSheet';

/**
 * TASK_WINDOW_REWORK slice 3a, rulings (b) + (c): a Board Edit override splits
 * into PARAMETER fields (goal, title, an existing compound child's goal ->
 * the placement) and everything else (the board-scoped task edit).
 */

const T0 = '2026-10-01T00:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: 'u', title: id, type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}

const run = (over: Partial<Task> = {}): Task =>
  task('r', { type: TaskType.COUNTING, title: 'Run 10 km', action: 'Run', unit: 'km', maxCount: 10, ...over });

function step(row: Task, over: Partial<ChildPatch> = {}): ChildPatch {
  const counting = row.type === TaskType.COUNTING;
  return {
    id: row.id, childTaskId: row.id, title: row.title, isCounting: counting, childType: row.type,
    action: row.action ?? '', goal: row.maxCount != null ? String(row.maxCount) : '', unit: row.unit ?? '',
    countKind: 'discrete', markedDeleted: false, ...over,
  };
}

function compound(children: ChildPatch[], over: Partial<TaskEditPatch> = {}): TaskEditPatch {
  return { title: 'H', action: '', goal: '', unit: '', children, operator: OperatorType.AND, ...over };
}

describe('splitBoardEditOverride — a counting task', () => {
  it('an untouched sheet submission splits to nothing', () => {
    const stored = run();
    const out = splitBoardEditOverride({
      stored,
      patch: { type: TaskType.COUNTING, title: 'Run 10 km', action: 'Run', maxCount: 10, unit: 'km', countKind: 'discrete' },
    });
    expect(out).toEqual({ params: {}, rest: null });
  });

  it('a goal edit is a PARAMETER in the goal\'s kind; the auto title carries no override', () => {
    const out = splitBoardEditOverride({
      stored: run(),
      patch: { type: TaskType.COUNTING, title: 'Run 8 km', action: 'Run', maxCount: 8, unit: 'km', countKind: 'discrete' },
    });
    expect(out.params).toEqual({ targetOverride: 8, targetKind: 'discrete' });
    expect(out.rest).toBeNull();
  });

  it('judges "changed" against the PLACEMENT: reopening an overridden square writes nothing, and returning to the own goal clears it', () => {
    const placement = { targetOverride: 7, targetKind: 'discrete' as const };
    const reopen = splitBoardEditOverride({
      stored: run(),
      placement,
      patch: { type: TaskType.COUNTING, title: 'Run 7 km', action: 'Run', maxCount: 7, unit: 'km', countKind: 'discrete' },
    });
    expect(reopen).toEqual({ params: {}, rest: null });

    const back = splitBoardEditOverride({
      stored: run(),
      placement,
      patch: { type: TaskType.COUNTING, title: 'Run 10 km', action: 'Run', maxCount: 10, unit: 'km', countKind: 'discrete' },
    });
    expect(back.params).toEqual({ targetOverride: null });
  });

  it('a custom title is a PARAMETER (titleOverride); retyping the stored title clears an existing one', () => {
    const named = splitBoardEditOverride({
      stored: run(),
      patch: { type: TaskType.COUNTING, title: 'Morning run', action: 'Run', maxCount: 10, unit: 'km', countKind: 'discrete' },
    });
    expect(named.params).toEqual({ titleOverride: 'Morning run' });
    expect(named.rest).toBeNull();

    const cleared = splitBoardEditOverride({
      stored: run(),
      placement: { titleOverride: 'Morning run' },
      patch: { type: TaskType.COUNTING, title: 'Run 10 km', action: 'Run', maxCount: 10, unit: 'km', countKind: 'discrete' },
    });
    expect(cleared.params).toEqual({ titleOverride: null });
  });

  it('action / unit are NOT parameters: they stay for the task edit (title re-derived at the task\'s own goal) while the goal rides on the placement', () => {
    const out = splitBoardEditOverride({
      stored: run(),
      patch: { type: TaskType.COUNTING, title: 'Walk 8 mi', action: 'Walk', maxCount: 8, unit: 'mi', countKind: 'discrete' },
    });
    expect(out.params).toEqual({ targetOverride: 8, targetKind: 'discrete' });
    expect(out.rest).toEqual({ action: 'Walk', unit: 'mi', title: 'Walk 10 mi' });
  });

  it('a kind switch is NOT a parameter; the goal is expressed in the NEW kind', () => {
    const out = splitBoardEditOverride({
      stored: run({ maxCount: 26.2, countKind: 'continuous', title: 'Run 26.2 km' }),
      patch: { type: TaskType.COUNTING, title: 'Run 30 km', action: 'Run', maxCount: 30, unit: 'km', countKind: 'discrete' },
    });
    expect(out.rest).toEqual({ countKind: 'discrete' });
    expect(out.params).toEqual({ targetOverride: 30, targetKind: 'discrete' });
  });

  it('a type change takes the whole override down the task path, untouched', () => {
    const patch = { type: TaskType.NORMAL, title: 'Run', action: undefined, unit: undefined, maxCount: undefined };
    expect(splitBoardEditOverride({ stored: run(), patch })).toEqual({ params: {}, rest: patch });
  });
});

describe('splitBoardEditOverride — a simple task', () => {
  it('a rename is a titleOverride; a description edit is the task path', () => {
    const stored = task('n', { title: 'Read' });
    expect(splitBoardEditOverride({ stored, patch: { title: 'Read 20 pages' } })).toEqual({
      params: { titleOverride: 'Read 20 pages' },
      rest: null,
    });
    expect(splitBoardEditOverride({ stored, patch: { title: 'Read', description: 'daily' } })).toEqual({
      params: {},
      rest: { description: 'daily' },
    });
  });
});

describe('splitBoardEditOverride — a compound', () => {
  const kid = run({ id: 'k', title: 'Run 10 km' });
  const other = task('o', { title: 'Coffee' });
  const stored = task('H', { type: TaskType.COMPOUND, operator: OperatorType.AND });
  const children = [kid, other];

  it('a goal edit on an EXISTING counting child is a childTargets entry; the structure is untouched', () => {
    const out = splitBoardEditOverride({
      stored,
      storedChildren: children,
      patch: { title: 'H', compound: compound([step(kid, { goal: '12' }), step(other)]) },
    });
    expect(out.params).toEqual({ childTargets: [{ childId: 'k', target: 12 }] });
    expect(out.rest).toBeNull();
  });

  it('merges with existing entries and drops one set back to the child\'s own goal', () => {
    const placement = { childTargets: [{ childId: 'k', target: 12 }, { childId: 'z', target: 3 }] };
    const out = splitBoardEditOverride({
      stored,
      placement,
      storedChildren: children,
      patch: { title: 'H', compound: compound([step(kid, { goal: '10' }), step(other)]) },
    });
    expect(out.params).toEqual({ childTargets: [{ childId: 'z', target: 3 }] });
  });

  it('removing the last entry clears childTargets', () => {
    const out = splitBoardEditOverride({
      stored,
      placement: { childTargets: [{ childId: 'k', target: 12 }] },
      storedChildren: children,
      patch: { title: 'H', compound: compound([step(kid, { goal: '10' }), step(other)]) },
    });
    expect(out.params).toEqual({ childTargets: null });
  });

  it('structure edits stay for the task path with existing goals reset: operator, a child title, an added or removed child', () => {
    const goalOnly = compound([step(kid, { goal: '12' }), step(other)]);
    const operator = splitBoardEditOverride({
      stored, storedChildren: children, patch: { title: 'H', compound: { ...goalOnly, operator: OperatorType.OR } },
    });
    expect(operator.params).toEqual({ childTargets: [{ childId: 'k', target: 12 }] });
    expect(operator.rest?.compound?.operator).toBe(OperatorType.OR);
    expect(operator.rest?.compound?.children[0].goal).toBe('10'); // the goal edit is NOT applied to the child task

    const retitled = splitBoardEditOverride({
      stored, storedChildren: children, patch: { title: 'H', compound: compound([step(kid), step(other, { title: 'Tea' })]) },
    });
    expect(retitled.rest?.compound).toBeDefined();

    const removed = splitBoardEditOverride({
      stored, storedChildren: children, patch: { title: 'H', compound: compound([step(kid), step(other, { markedDeleted: true })]) },
    });
    expect(removed.rest?.compound).toBeDefined();

    const added = splitBoardEditOverride({
      stored,
      storedChildren: children,
      patch: { title: 'H', compound: compound([step(kid), step(other), { ...step(other), id: 'n', childTaskId: null, title: 'New' }]) },
    });
    expect(added.rest?.compound).toBeDefined();
  });

  it('a compound rename keeps the stored title inside the task-path structure', () => {
    const out = splitBoardEditOverride({
      stored,
      storedChildren: children,
      patch: { title: 'Renamed', compound: compound([step(kid), step(other, { markedDeleted: true })], { title: 'Renamed' }) },
    });
    expect(out.params).toEqual({ titleOverride: 'Renamed' });
    expect(out.rest?.compound?.title).toBe('H');
  });
});

describe('patchHasNonParameterFields (the sheet\'s fork gate)', () => {
  it('is false for goal / title / child-goal edits and true for anything else', () => {
    const stored = run();
    expect(patchHasNonParameterFields(stored, { type: TaskType.COUNTING, title: 'Run 8 km', action: 'Run', maxCount: 8, unit: 'km', countKind: 'discrete' })).toBe(false);
    expect(patchHasNonParameterFields(stored, { type: TaskType.COUNTING, title: 'Run 8 mi', action: 'Run', maxCount: 8, unit: 'mi', countKind: 'discrete' })).toBe(true);
    expect(patchHasNonParameterFields(stored, { type: TaskType.NORMAL, title: 'Run' })).toBe(true);

    const kid = run({ id: 'k' });
    const h = task('H', { type: TaskType.COMPOUND, operator: OperatorType.AND });
    expect(patchHasNonParameterFields(h, { title: 'H', compound: compound([step(kid, { goal: '12' })]) }, [kid])).toBe(false);
    expect(patchHasNonParameterFields(h, { title: 'H', compound: compound([step(kid, { action: 'Walk' })]) }, [kid])).toBe(true);
  });
});
