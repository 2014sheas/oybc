import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import {
  type ChildPatch,
  type TaskEditPatch,
  applyPatchToTask,
  childPatchFromTask,
  clampThreshold,
  countingPreview,
  emptyPatch,
  isNewChild,
  liveChildren,
  newChildPatch,
  patchFromTask,
  patchesEqual,
  readsAsPreview,
  seedPatchForEditor,
  validatePatch,
} from './taskEditPatch';

/**
 * Web port of `TaskEditPatchTests.swift` — same case list, ported to the
 * plain-object/pure-function shape (no `struct` methods on the TS side).
 * Inline Task Editing, web PR-2.
 */

function makeTask(over: Partial<Task> = {}): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Task',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function countingPatch(
  title = 'Run',
  action = 'Run',
  goal = '5',
  unit = 'km',
): TaskEditPatch {
  return { ...emptyPatch(title), action, goal, unit };
}

function simpleStep(title: string, id = 'c1'): ChildPatch {
  return { id, childTaskId: id, title, isCounting: false, action: '', goal: '', unit: '', markedDeleted: false };
}

function progressStep(title: string, id = 'p1', goal = '3', unit = 'km'): ChildPatch {
  return { id, childTaskId: id, title, isCounting: true, action: title, goal, unit, markedDeleted: false };
}

function compoundPatch(children: ChildPatch[], title = 'Routine'): TaskEditPatch {
  return { ...emptyPatch(title), children };
}

describe('taskEditPatch — validation', () => {
  it('counting: zero goal blocks', () => {
    expect(validatePatch({ ...countingPatch(), goal: '0' }, TaskType.COUNTING)).toBe(
      'Set a goal above zero.',
    );
  });

  it('counting: unparsed goal blocks', () => {
    expect(validatePatch({ ...countingPatch(), goal: 'abc' }, TaskType.COUNTING)).toBe(
      'Set a goal above zero.',
    );
  });

  it('counting: empty unit blocks', () => {
    expect(validatePatch({ ...countingPatch(), unit: '  ' }, TaskType.COUNTING)).toBe(
      'Add a unit, like km or pages.',
    );
  });

  it('counting: valid patch passes', () => {
    expect(validatePatch(countingPatch(), TaskType.COUNTING)).toBeNull();
  });

  it('normal: empty title blocks', () => {
    expect(validatePatch(emptyPatch('   '), TaskType.NORMAL)).toBe('A title is required.');
  });

  it('normal: only needs a title', () => {
    expect(validatePatch(emptyPatch('Stretch'), TaskType.NORMAL)).toBeNull();
  });
});

describe('taskEditPatch — patchFromTask', () => {
  it('clones fields from a counting task', () => {
    const base = makeTask({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5 });
    const p = patchFromTask(base);
    expect(p.title).toBe('Run 5 km');
    expect(p.action).toBe('Run');
    expect(p.goal).toBe('5');
    expect(p.unit).toBe('km');
  });

  it('seeds operator and threshold from a compound task', () => {
    const base = makeTask({ type: TaskType.COMPOUND, title: 'Routine', operator: OperatorType.M_OF_N, threshold: 3 });
    const p = patchFromTask(base);
    expect(p.operator).toBe(OperatorType.M_OF_N);
    expect(p.threshold).toBe(3);
  });
});

describe('taskEditPatch — applyPatchToTask', () => {
  it('counting: updates fields and auto-titles on a blank title', () => {
    const base = makeTask({ type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5 });
    const p: TaskEditPatch = { ...patchFromTask(base), title: '', action: 'Walk', goal: '3', unit: 'mi' };
    const out = applyPatchToTask(p, base);
    expect(out.action).toBe('Walk');
    expect(out.maxCount).toBe(3);
    expect(out.unit).toBe('mi');
    expect(out.title).toBe(generateCounterTaskTitle('Walk', 3, 'mi'));
  });

  it('counting: keeps a typed title', () => {
    const base = makeTask({ type: TaskType.COUNTING, title: 'Old', action: 'Run', unit: 'km', maxCount: 5 });
    const p: TaskEditPatch = { ...patchFromTask(base), title: 'My run' };
    expect(applyPatchToTask(p, base).title).toBe('My run');
  });

  it('normal: sets the title', () => {
    const base = makeTask({ type: TaskType.NORMAL, title: 'Old' });
    const out = applyPatchToTask(emptyPatch('Renamed'), base);
    expect(out.title).toBe('Renamed');
  });
});

describe('taskEditPatch — countingPreview / readsAsPreview', () => {
  it('renders the full preview string', () => {
    expect(countingPreview(countingPatch())).toBe('Reads as: Run — 5 — km');
  });

  it('renders dashes for missing fields', () => {
    const p: TaskEditPatch = { ...emptyPatch(''), action: 'Run' };
    expect(countingPreview(p)).toBe('Reads as: Run — — — —');
  });

  it('is undefined when every field is blank', () => {
    expect(countingPreview(emptyPatch('anything'))).toBeUndefined();
  });

  it('readsAsPreview matches countingPreview directly', () => {
    expect(readsAsPreview('Run', '5', 'km')).toBe('Reads as: Run — 5 — km');
    expect(readsAsPreview('', '', '')).toBeUndefined();
  });
});

describe('taskEditPatch — ChildPatch construction', () => {
  it('a counting child becomes a counting sub-task', () => {
    const child = makeTask({ id: 'cc', type: TaskType.COUNTING, title: 'Run 3 km', action: 'Run', unit: 'km', maxCount: 3 });
    const cp = childPatchFromTask(child);
    expect(cp.isCounting).toBe(true);
    expect(cp.childTaskId).toBe('cc');
    expect(cp.action).toBe('Run');
    expect(cp.goal).toBe('3');
    expect(cp.unit).toBe('km');
    expect(isNewChild(cp)).toBe(false);
  });

  it('a normal child becomes a normal sub-task', () => {
    const cp = childPatchFromTask(makeTask({ id: 'cn', type: TaskType.NORMAL, title: 'Stretch' }));
    expect(cp.isCounting).toBe(false);
    expect(cp.title).toBe('Stretch');
  });

  it('newChildPatch mints an unlinked (isNew) child', () => {
    const cp = newChildPatch(true);
    expect(isNewChild(cp)).toBe(true);
    expect(cp.isCounting).toBe(true);
    expect(cp.title).toBe('');
  });
});

describe('taskEditPatch — compound validation', () => {
  it('empty title blocks', () => {
    const p = { ...compoundPatch([simpleStep('A', 'a'), simpleStep('B', 'b')]), title: '  ' };
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('A title is required.');
  });

  it('needs two sub-tasks', () => {
    const p = compoundPatch([simpleStep('only', 'a')]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('A compound task needs at least two sub-tasks.');
  });

  it('blank-titled sub-tasks do not count', () => {
    const p = compoundPatch([simpleStep('A', 'a'), simpleStep('   ', 'b'), simpleStep('', 'c')]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('A compound task needs at least two sub-tasks.');
  });

  it('deleted sub-tasks do not count', () => {
    const deleted = { ...simpleStep('B', 'b'), markedDeleted: true };
    const p = compoundPatch([simpleStep('A', 'a'), deleted]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('A compound task needs at least two sub-tasks.');
  });

  it('two normal sub-tasks is valid', () => {
    const p = compoundPatch([simpleStep('A', 'a'), simpleStep('B', 'b')]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBeNull();
  });

  it('a counting sub-task missing a goal blocks', () => {
    const noGoal = { ...progressStep('Run', 'p'), goal: '0' };
    const p = compoundPatch([simpleStep('A', 'a'), noGoal]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('Counting sub-task "Run" needs a goal and a unit.');
  });

  it('a counting sub-task missing a unit blocks', () => {
    const noUnit = { ...progressStep('Run', 'p'), unit: '' };
    const p = compoundPatch([simpleStep('A', 'a'), noUnit]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('Counting sub-task "Run" needs a goal and a unit.');
  });

  it('a valid counting sub-task passes', () => {
    const p = compoundPatch([simpleStep('A', 'a'), progressStep('Run', 'p')]);
    expect(validatePatch(p, TaskType.COMPOUND)).toBeNull();
  });

  it('applyPatchToTask sets the compound title', () => {
    const base = makeTask({ id: 'cmp', type: TaskType.COMPOUND, title: 'Old' });
    const p = compoundPatch([simpleStep('A', 'a'), simpleStep('B', 'b')], 'Morning');
    expect(applyPatchToTask(p, base).title).toBe('Morning');
  });
});

describe('taskEditPatch — operator / threshold', () => {
  function twoSteps(): ChildPatch[] {
    return [simpleStep('A', 'a'), simpleStep('B', 'b')];
  }

  it('M_OF_N with no threshold blocks', () => {
    const p: TaskEditPatch = { ...compoundPatch(twoSteps()), operator: OperatorType.M_OF_N, threshold: undefined };
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('Choose how many sub-tasks must complete.');
  });

  it('M_OF_N with threshold above the live count blocks', () => {
    const p: TaskEditPatch = { ...compoundPatch(twoSteps()), operator: OperatorType.M_OF_N, threshold: 3 };
    expect(validatePatch(p, TaskType.COMPOUND)).toBe('Choose how many sub-tasks must complete.');
  });

  it('M_OF_N with a valid threshold passes', () => {
    const p: TaskEditPatch = { ...compoundPatch(twoSteps()), operator: OperatorType.M_OF_N, threshold: 2 };
    expect(validatePatch(p, TaskType.COMPOUND)).toBeNull();
  });

  it.each([OperatorType.AND, OperatorType.OR])('%s does not require a threshold', (op) => {
    const p: TaskEditPatch = { ...compoundPatch(twoSteps()), operator: op, threshold: undefined };
    expect(validatePatch(p, TaskType.COMPOUND)).toBeNull();
  });

  it('applyPatchToTask round-trips operator and threshold', () => {
    const base = makeTask({ id: 'cmp', type: TaskType.COMPOUND, title: 'Old' });
    const p: TaskEditPatch = {
      ...compoundPatch(twoSteps(), 'Morning'),
      operator: OperatorType.M_OF_N,
      threshold: 2,
    };
    const out = applyPatchToTask(p, base);
    expect(out.operator).toBe(OperatorType.M_OF_N);
    expect(out.threshold).toBe(2);
  });

  it('applyPatchToTask clears the threshold for AND', () => {
    const base = makeTask({ id: 'cmp', type: TaskType.COMPOUND, title: 'Old' });
    const p: TaskEditPatch = {
      ...compoundPatch(twoSteps(), 'Morning'),
      operator: OperatorType.AND,
      threshold: 5, // stale — AND carries no threshold.
    };
    const out = applyPatchToTask(p, base);
    expect(out.operator).toBe(OperatorType.AND);
    expect(out.threshold).toBeUndefined();
  });

  it('applyPatchToTask clamps a stale threshold to the live child count', () => {
    const base = makeTask({ id: 'cmp', type: TaskType.COMPOUND, title: 'Old' });
    const p: TaskEditPatch = {
      ...compoundPatch(twoSteps(), 'Morning'),
      operator: OperatorType.M_OF_N,
      threshold: 99,
    };
    expect(applyPatchToTask(p, base).threshold).toBe(2);
  });

  it('applyPatchToTask clamps an undefined threshold to 1', () => {
    const base = makeTask({ id: 'cmp', type: TaskType.COMPOUND, title: 'Old' });
    const p: TaskEditPatch = {
      ...compoundPatch(twoSteps(), 'Morning'),
      operator: OperatorType.M_OF_N,
      threshold: undefined,
    };
    expect(applyPatchToTask(p, base).threshold).toBe(1);
  });

  it('clampThreshold clamps into [1, max(1, count)]', () => {
    expect(clampThreshold(99, 2)).toBe(2);
    expect(clampThreshold(0, 2)).toBe(1);
    expect(clampThreshold(1, 0)).toBe(1);
  });
});

describe('taskEditPatch — seedPatchForEditor', () => {
  it('blanks a counting title that matches its auto-generated form', () => {
    const autoTitle = generateCounterTaskTitle('Run', 5, 'km');
    const base = makeTask({ type: TaskType.COUNTING, title: autoTitle, action: 'Run', unit: 'km', maxCount: 5 });
    const p = seedPatchForEditor(base);
    expect(p.title).toBe('');
    expect(p.action).toBe('Run');
    expect(p.goal).toBe('5');
    expect(p.unit).toBe('km');
  });

  it('keeps a custom counting title', () => {
    const base = makeTask({ type: TaskType.COUNTING, title: 'My custom run', action: 'Run', unit: 'km', maxCount: 5 });
    expect(seedPatchForEditor(base).title).toBe('My custom run');
  });

  it('does not affect a normal task', () => {
    const base = makeTask({ type: TaskType.NORMAL, title: 'Stretch' });
    expect(seedPatchForEditor(base).title).toBe('Stretch');
  });

  it('a reseeded blank title still re-derives on apply', () => {
    const autoTitle = generateCounterTaskTitle('Run', 5, 'km');
    const base = makeTask({ type: TaskType.COUNTING, title: autoTitle, action: 'Run', unit: 'km', maxCount: 5 });
    const p = { ...seedPatchForEditor(base), goal: '10' };
    const out = applyPatchToTask(p, base);
    expect(out.title).toBe(generateCounterTaskTitle('Run', 10, 'km'));
  });
});

describe('taskEditPatch — liveChildren / patchesEqual', () => {
  it('liveChildren drops deleted and blank-titled entries', () => {
    const deleted = { ...simpleStep('B', 'b'), markedDeleted: true };
    const blank = simpleStep('  ', 'c');
    const kept = simpleStep('A', 'a');
    expect(liveChildren(compoundPatch([kept, deleted, blank]))).toEqual([kept]);
  });

  it('patchesEqual compares fields and children element-wise', () => {
    const a = compoundPatch([simpleStep('A', 'a')]);
    const b = compoundPatch([simpleStep('A', 'a')]);
    expect(patchesEqual(a, b)).toBe(true);
    const c = compoundPatch([simpleStep('A changed', 'a')]);
    expect(patchesEqual(a, c)).toBe(false);
  });
});
