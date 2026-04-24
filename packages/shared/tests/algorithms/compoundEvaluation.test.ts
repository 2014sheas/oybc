import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { OperatorType, TaskType } from '../../src/constants/enums';
import type { Task, CompoundChild } from '../../src';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function child(
  parentId: string,
  childId: string,
  idx: number,
  overrides: Partial<CompoundChild> = {},
): CompoundChild {
  return {
    id: `${parentId}-${childId}-${idx}`,
    compoundTaskId: parentId,
    childTaskId: childId,
    childIndex: idx,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function compoundTask(id: string, operator: OperatorType, overrides: Partial<Task> = {}): Task {
  return task(id, { type: TaskType.COMPOUND, operator, ...overrides });
}

// ─── AND operator ─────────────────────────────────────────────────────────────

describe('evaluateCompound — AND operator', () => {
  it('returns false when one of two children is incomplete', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    const a = task('a', { isCompleted: true });
    const b = task('b', { isCompleted: false });
    const childrenByCompound = { parent: [child('parent', 'a', 0), child('parent', 'b', 1)] };
    const taskById = { parent, a, b };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });

  it('returns true when both children are complete', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    const a = task('a', { isCompleted: true });
    const b = task('b', { isCompleted: true });
    const childrenByCompound = { parent: [child('parent', 'a', 0), child('parent', 'b', 1)] };
    const taskById = { parent, a, b };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });

  it('returns true for zero non-deleted children (vacuous truth)', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    const childrenByCompound = { parent: [] };
    const taskById = { parent };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });

  it('filters soft-deleted children — one complete + one soft-deleted-incomplete → true', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    const a = task('a', { isCompleted: true });
    const b = task('b', { isCompleted: false });
    const childrenByCompound = {
      parent: [child('parent', 'a', 0), child('parent', 'b', 1, { isDeleted: true })],
    };
    const taskById = { parent, a, b };
    // 'b' is soft-deleted on the link — treated as absent; only 'a' remains → AND of [true] = true
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });
});

// ─── OR operator ──────────────────────────────────────────────────────────────

describe('evaluateCompound — OR operator', () => {
  it('returns true when at least one of three children is complete', () => {
    const parent = compoundTask('parent', OperatorType.OR);
    const a = task('a', { isCompleted: false });
    const b = task('b', { isCompleted: true });
    const c = task('c', { isCompleted: false });
    const childrenByCompound = {
      parent: [child('parent', 'a', 0), child('parent', 'b', 1), child('parent', 'c', 2)],
    };
    const taskById = { parent, a, b, c };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });

  it('returns false when all children are incomplete', () => {
    const parent = compoundTask('parent', OperatorType.OR);
    const a = task('a', { isCompleted: false });
    const b = task('b', { isCompleted: false });
    const childrenByCompound = { parent: [child('parent', 'a', 0), child('parent', 'b', 1)] };
    const taskById = { parent, a, b };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });

  it('returns false for zero non-deleted children', () => {
    const parent = compoundTask('parent', OperatorType.OR);
    const childrenByCompound = { parent: [] };
    const taskById = { parent };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });
});

// ─── M_OF_N operator ──────────────────────────────────────────────────────────

describe('evaluateCompound — M_OF_N operator', () => {
  it('returns true when 2 of 3 children are complete (threshold=2)', () => {
    const parent = compoundTask('parent', OperatorType.M_OF_N, { threshold: 2 });
    const a = task('a', { isCompleted: true });
    const b = task('b', { isCompleted: true });
    const c = task('c', { isCompleted: false });
    const childrenByCompound = {
      parent: [child('parent', 'a', 0), child('parent', 'b', 1), child('parent', 'c', 2)],
    };
    const taskById = { parent, a, b, c };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });

  it('returns false when 1 of 3 children is complete (threshold=2)', () => {
    const parent = compoundTask('parent', OperatorType.M_OF_N, { threshold: 2 });
    const a = task('a', { isCompleted: true });
    const b = task('b', { isCompleted: false });
    const c = task('c', { isCompleted: false });
    const childrenByCompound = {
      parent: [child('parent', 'a', 0), child('parent', 'b', 1), child('parent', 'c', 2)],
    };
    const taskById = { parent, a, b, c };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });

  it('returns true when threshold is missing (treats threshold as 0 — >= 0 always passes)', () => {
    // Defensive: Zod should reject M_OF_N without threshold; this test pins the algorithm's fallback behavior.
    const parent = compoundTask('parent', OperatorType.M_OF_N); // no threshold
    const a = task('a', { isCompleted: false });
    const childrenByCompound = { parent: [child('parent', 'a', 0)] };
    const taskById = { parent, a };
    // compound.threshold ?? 0 → 0; filter(Boolean).length (0) >= 0 → true
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });
});

// ─── Nested compounds ─────────────────────────────────────────────────────────

describe('evaluateCompound — nested compounds', () => {
  it('evaluates a nested compound child recursively', () => {
    // parent AND of [primitive, childCompound]
    // childCompound is OR of [a, b]
    // primitive: complete; a: incomplete; b: complete → childCompound complete via OR → parent complete
    const parent = compoundTask('parent', OperatorType.AND);
    const primitive = task('primitive', { isCompleted: true });
    const childCompound = compoundTask('childCompound', OperatorType.OR);
    const a = task('a', { isCompleted: false });
    const b = task('b', { isCompleted: true });

    const childrenByCompound = {
      parent: [child('parent', 'primitive', 0), child('parent', 'childCompound', 1)],
      childCompound: [child('childCompound', 'a', 0), child('childCompound', 'b', 1)],
    };
    const taskById = { parent, primitive, childCompound, a, b };

    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });
});

// ─── Edge cases ───────────────────────────────────────────────────────────────

describe('evaluateCompound — edge cases', () => {
  it('treats a child whose taskId is missing from taskById as incomplete', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    // child link references 'ghost' but 'ghost' is not in taskById
    const childrenByCompound = { parent: [child('parent', 'ghost', 0)] };
    const taskById = { parent };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });

  it('treats a child whose Task has isDeleted=true as incomplete', () => {
    const parent = compoundTask('parent', OperatorType.AND);
    // The Task row itself is soft-deleted (distinct from the link being deleted)
    const deletedChild = task('d', { isCompleted: true, isDeleted: true });
    const childrenByCompound = { parent: [child('parent', 'd', 0)] };
    const taskById = { parent, d: deletedChild };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
  });

  it('returns task.isCompleted directly for non-compound tasks (uniform evaluator behavior)', () => {
    const normalTask = task('t', { isCompleted: true });
    expect(evaluateCompound(normalTask, {}, {})).toBe(true);

    const incompleteTask = task('t2', { isCompleted: false });
    expect(evaluateCompound(incompleteTask, {}, {})).toBe(false);
  });

  it('returns false for a compound with undefined operator (default branch)', () => {
    // operator is intentionally omitted to simulate a malformed row
    const malformed = task('malformed', { type: TaskType.COMPOUND, operator: undefined });
    const childrenByCompound = { malformed: [] };
    const taskById = { malformed };
    expect(evaluateCompound(malformed, childrenByCompound, taskById)).toBe(false);
  });

  it('handles compound id missing entirely from childrenByCompound (defensive)', () => {
    // 'parent' key is absent from childrenByCompound — treated as empty children list
    const compound = compoundTask('parent', OperatorType.AND);
    const childrenByCompound: Record<string, CompoundChild[]> = {}; // 'parent' key absent
    const taskById = { parent: compound };
    // AND of zero non-deleted children → vacuous truth
    expect(evaluateCompound(compound, childrenByCompound, taskById)).toBe(true);
  });
});
