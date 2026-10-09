import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType, type Task } from '@oybc/shared';
import { newChildPatch, type TaskEditPatch } from '../../../db/taskEditPatch';
import {
  buildSheetOverride,
  seedCompoundDraft,
  seedSheetTitle,
  sheetValidationProblem,
  showsCompoundEditor,
  type SheetInput,
} from '../boardEditTaskSheetModel';
import { typeControlMode } from '../../taskEdit/taskTypeRules';

function task(over: Partial<Task> = {}): Task {
  return {
    id: 't1', userId: 'u', title: 'Walk', type: TaskType.NORMAL,
    isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: '', updatedAt: '', version: 1, isDeleted: false,
    ...over,
  };
}

function kid(title: string): ReturnType<typeof newChildPatch> {
  return { ...newChildPatch(false), title };
}

function input(over: Partial<SheetInput> = {}): SheetInput {
  const original = over.original ?? task();
  return {
    original, selected: original.type, title: original.title,
    action: '', goalStr: '', unit: '', countKind: 'discrete', compoundDraft: null,
    ...over,
  };
}

function draft(over: Partial<TaskEditPatch> = {}): TaskEditPatch {
  return {
    title: 'x', action: '', goal: '', unit: '',
    children: [kid('a'), kid('b')], operator: OperatorType.AND,
    ...over,
  };
}

describe('typeControlMode / showsCompoundEditor', () => {
  it('switch for Simple/Counting, fixed for Compound, none for Achievement', () => {
    expect(typeControlMode(TaskType.NORMAL)).toBe('switch');
    expect(typeControlMode(TaskType.COUNTING)).toBe('switch');
    expect(typeControlMode(TaskType.COMPOUND)).toBe('fixed');
    expect(typeControlMode(TaskType.ACHIEVEMENT)).toBe('none');
  });

  it('a linked counter shows its type fixed (no switch)', () => {
    expect(typeControlMode(TaskType.COUNTING, true)).toBe('fixed');
    expect(typeControlMode(TaskType.NORMAL, true)).toBe('fixed');
  });

  it('the compound editor is open only for the Compound selection', () => {
    expect(showsCompoundEditor(TaskType.COMPOUND)).toBe(true);
    expect(showsCompoundEditor(TaskType.NORMAL)).toBe(false);
    expect(showsCompoundEditor(TaskType.COUNTING)).toBe(false);
  });
});

describe('seedCompoundDraft', () => {
  it('a non-compound task seeds an empty-children draft with the default AND operator', () => {
    const d = seedCompoundDraft(task({ title: 'Walk' }), [task({ id: 'ignored' })]);
    expect(d.children).toEqual([]);
    expect(d.title).toBe('Walk');
    expect(d.operator).toBe(OperatorType.AND);
  });

  it('an existing compound seeds its live child tasks, rule and threshold', () => {
    const parent = task({ type: TaskType.COMPOUND, operator: OperatorType.M_OF_N, threshold: 2 });
    const d = seedCompoundDraft(parent, [
      task({ id: 'c1', title: 'One' }),
      task({ id: 'c2', title: 'Two', isDeleted: true }),
      task({ id: 'c3', title: 'Three', type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5 }),
    ]);
    expect(d.children.map((c) => c.childTaskId)).toEqual(['c1', 'c3']);
    expect(d.children[1]).toMatchObject({ isCounting: true, goal: '5', unit: 'km' });
    expect(d).toMatchObject({ operator: OperatorType.M_OF_N, threshold: 2 });
  });
});

describe('seedSheetTitle', () => {
  it('an auto Counting title seeds blank', () => {
    expect(seedSheetTitle(task({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('');
    // Trailing whitespace is still the auto title; an empty title is too.
    expect(seedSheetTitle(task({ type: TaskType.COUNTING, title: ' Run 5 km ', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('');
    expect(seedSheetTitle(task({ type: TaskType.COUNTING, title: '', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('');
  });

  it('a custom Counting title seeds as-is (case-sensitive compare)', () => {
    expect(seedSheetTitle(task({ type: TaskType.COUNTING, title: 'Morning run', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('Morning run');
    expect(seedSheetTitle(task({ type: TaskType.COUNTING, title: 'run 5 km', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('run 5 km');
  });

  it('a non-Counting task seeds its title verbatim even when it looks generated', () => {
    expect(seedSheetTitle(task({ title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' }))).toBe('Run 5 km');
    expect(seedSheetTitle(task({ type: TaskType.COMPOUND, title: 'Combo' }))).toBe('Combo');
  });
});

describe('sheetValidationProblem', () => {
  it('Simple needs a title', () => {
    expect(sheetValidationProblem(input({ title: '  ' }))).not.toBeNull();
    expect(sheetValidationProblem(input({ title: 'ok' }))).toBeNull();
  });

  it('Counting (incl. Simple→Counting) needs a goal and a unit; title optional', () => {
    const base = { selected: TaskType.COUNTING, title: '' } as const;
    expect(sheetValidationProblem(input({ ...base, goalStr: '', unit: 'km' }))).toMatch(/goal/);
    expect(sheetValidationProblem(input({ ...base, goalStr: '0', unit: 'km' }))).toMatch(/goal/);
    expect(sheetValidationProblem(input({ ...base, goalStr: '3', unit: ' ' }))).toMatch(/unit/);
    expect(sheetValidationProblem(input({ ...base, goalStr: '3', unit: 'km' }))).toBeNull();
  });

  it('Compound: needs title, >=1 sub-task, and a valid M_OF_N threshold', () => {
    const sel = { selected: TaskType.COMPOUND } as const;
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: null }))).toMatch(/Loading/);
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: draft({ children: [] }) }))).toMatch(/needs a sub-task/);
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: draft({ children: [kid('a')] }) }))).toBeNull();
    expect(sheetValidationProblem(input({ ...sel, title: '', compoundDraft: draft() }))).toMatch(/title/);
    expect(
      sheetValidationProblem(input({ ...sel, compoundDraft: draft({ operator: OperatorType.M_OF_N, threshold: 3 }) })),
    ).toMatch(/how many/);
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: draft() }))).toBeNull();
  });

  it('the title typed in the sheet (not the draft title) is what is validated', () => {
    const sel = { selected: TaskType.COMPOUND, title: 'Typed' } as const;
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: draft({ title: '' }) }))).toBeNull();
  });
});

describe('buildSheetOverride', () => {
  it('Simple rename: title, the unchanged type, and an explicit cleared compound', () => {
    expect(buildSheetOverride(input({ title: ' New ' }))).toEqual({ title: 'New', type: TaskType.NORMAL, compound: undefined });
  });

  it('Simple → Counting: type + counting fields; blank title auto-generates', () => {
    const o = buildSheetOverride(input({ selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '5', unit: 'km' }));
    expect(o).toMatchObject({ type: TaskType.COUNTING, action: 'Run', maxCount: 5, unit: 'km' });
    expect(o.title).toBeTruthy();
    expect(o.title).not.toBe('Walk');
  });

  it('a goal-only edit on an auto-titled Counting task regenerates the title at the new goal', () => {
    const counting = task({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' });
    // The sheet opens with the auto title blanked (seedSheetTitle) …
    const o = buildSheetOverride(input({ original: counting, title: seedSheetTitle(counting), action: 'Run', goalStr: '8', unit: 'km' }));
    expect(o.type).toBe(TaskType.COUNTING);
    // … so the stale "Run 5 km" is NOT carried onto a goal of 8.
    expect(o).toMatchObject({ title: 'Run 8 km', maxCount: 8 });
  });

  it('a custom Counting title survives a goal-only edit verbatim', () => {
    const counting = task({ type: TaskType.COUNTING, title: 'Morning run', action: 'Run', maxCount: 5, unit: 'km' });
    const o = buildSheetOverride(input({ original: counting, title: seedSheetTitle(counting), action: 'Run', goalStr: '8', unit: 'km' }));
    expect(o).toMatchObject({ title: 'Morning run', maxCount: 8 });
  });

  it('Counting → Simple: type + explicitly cleared action/unit/maxCount', () => {
    const counting = task({ type: TaskType.COUNTING, title: 'Run', action: 'Run', maxCount: 5, unit: 'km' });
    const o = buildSheetOverride(input({ original: counting, selected: TaskType.NORMAL, title: 'Run' }));
    expect(o).toMatchObject({ type: TaskType.NORMAL, title: 'Run' });
    expect('action' in o && o.action === undefined).toBe(true);
    expect('unit' in o && o.unit === undefined).toBe(true);
    expect('maxCount' in o && o.maxCount === undefined).toBe(true);
  });

  it('→ Compound: type + title + the compound structure titled from the sheet', () => {
    const o = buildSheetOverride(input({ selected: TaskType.COMPOUND, title: ' Combo ', compoundDraft: draft() }));
    expect(o.type).toBe(TaskType.COMPOUND);
    expect(o.title).toBe('Combo');
    expect(o.compound?.title).toBe('Combo');
    expect(o.compound?.children).toHaveLength(2);
  });

  it('an existing compound edit sends compound with the unchanged type', () => {
    const parent = task({ type: TaskType.COMPOUND });
    const o = buildSheetOverride(input({ original: parent, compoundDraft: draft() }));
    expect(o.type).toBe(TaskType.COMPOUND);
    expect(o.compound).toBeDefined();
  });

  it('switching back to the original type clears a staged structure (explicit compound: undefined)', () => {
    const o = buildSheetOverride(input({ selected: TaskType.NORMAL, compoundDraft: draft() }));
    expect(o.type).toBe(TaskType.NORMAL);
    expect('compound' in o && o.compound === undefined).toBe(true);
  });

  it('Counting original → Compound → back to Counting: no compound, counting fields from the sheet', () => {
    const counting = task({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' });
    const o = buildSheetOverride(input({ original: counting, selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '5', unit: 'km', compoundDraft: draft() }));
    expect(o).toMatchObject({ type: TaskType.COUNTING, title: 'Run 5 km', maxCount: 5 });
    expect('compound' in o && o.compound === undefined).toBe(true);
  });

  it('an UNEDITED existing compound submits no structure and skips structure validation', () => {
    const parent = task({ type: TaskType.COMPOUND, title: 'Combo' });
    const stored = draft({ children: [] }); // stored-invalid: 0 children
    const i = input({ original: parent, title: 'Renamed', compoundDraft: stored, compoundBaseline: stored });
    expect(sheetValidationProblem(i)).toBeNull();
    expect(buildSheetOverride(i).compound).toBeUndefined();
  });

  it('an EDITED existing compound is still validated and submitted', () => {
    const parent = task({ type: TaskType.COMPOUND, title: 'Combo' });
    const baseline = draft({ children: [kid('a'), kid('b')] });
    const edited = draft({ children: [] });
    expect(sheetValidationProblem(input({ original: parent, compoundDraft: edited, compoundBaseline: baseline }))).toMatch(/needs a sub-task/);
    const ok = draft({ children: [kid('a'), kid('b'), kid('c')] });
    expect(buildSheetOverride(input({ original: parent, compoundDraft: ok, compoundBaseline: baseline })).compound).toBeDefined();
  });
});
