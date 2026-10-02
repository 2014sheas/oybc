import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType, type Task } from '@oybc/shared';
import { newChildPatch, type TaskEditPatch } from '../../../db/taskEditPatch';
import {
  buildSheetOverride,
  seedCompoundDraft,
  sheetValidationProblem,
  showsCompoundEditor,
  typeControlMode,
  type SheetInput,
} from '../boardEditTaskSheetModel';

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
    action: '', goalStr: '', unit: '', compoundDraft: null,
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

  it('the compound editor is open only for the Compound selection', () => {
    expect(showsCompoundEditor(TaskType.COMPOUND)).toBe(true);
    expect(showsCompoundEditor(TaskType.NORMAL)).toBe(false);
    expect(showsCompoundEditor(TaskType.COUNTING)).toBe(false);
  });
});

describe('seedCompoundDraft', () => {
  it('a non-compound task seeds an empty-children draft with no operator', () => {
    const d = seedCompoundDraft(task({ title: 'Walk' }), [task({ id: 'ignored' })]);
    expect(d.children).toEqual([]);
    expect(d.title).toBe('Walk');
    expect(d.operator).toBeUndefined();
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

  it('Compound: needs title, >=2 sub-tasks, and a valid M_OF_N threshold', () => {
    const sel = { selected: TaskType.COMPOUND } as const;
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: null }))).toMatch(/Loading/);
    expect(sheetValidationProblem(input({ ...sel, compoundDraft: draft({ children: [kid('a')] }) }))).toMatch(/two sub-tasks/);
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
  it('Simple rename: title only, no type', () => {
    expect(buildSheetOverride(input({ title: ' New ' }))).toEqual({ title: 'New' });
  });

  it('Simple → Counting: type + counting fields; blank title auto-generates', () => {
    const o = buildSheetOverride(input({ selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '5', unit: 'km' }));
    expect(o).toMatchObject({ type: TaskType.COUNTING, action: 'Run', maxCount: 5, unit: 'km' });
    expect(o.title).toBeTruthy();
    expect(o.title).not.toBe('Walk');
  });

  it('Counting edit keeps the stored title when blank and sends no type', () => {
    const counting = task({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' });
    const o = buildSheetOverride(input({ original: counting, title: '', action: 'Run', goalStr: '8', unit: 'km' }));
    expect(o.type).toBeUndefined();
    expect(o).toMatchObject({ title: 'Run 5 km', maxCount: 8 });
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

  it('an existing compound edit sends compound but no type', () => {
    const parent = task({ type: TaskType.COMPOUND });
    const o = buildSheetOverride(input({ original: parent, compoundDraft: draft() }));
    expect(o.type).toBeUndefined();
    expect(o.compound).toBeDefined();
  });
});
