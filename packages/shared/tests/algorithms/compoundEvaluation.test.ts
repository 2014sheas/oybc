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

  it('treats a missing threshold as 1 (degenerate-OR), not as 0 (vacuous-true)', () => {
    // Defensive: Zod should reject M_OF_N without threshold, but a malformed
    // legacy composite migrated without a root threshold could land here. The
    // algorithm floors at max(1, threshold ?? 1) so the worst case behaves
    // like OR (one child satisfies it) rather than always-complete.
    const parent = compoundTask('parent', OperatorType.M_OF_N); // no threshold
    const a = task('a', { isCompleted: false });
    const childrenByCompound = { parent: [child('parent', 'a', 0)] };
    const taskById = { parent, a };
    // No completed children → cannot satisfy required=1 → false.
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);

    // One completed child → required=1 satisfied → true.
    const aDone = task('a', { isCompleted: true });
    expect(
      evaluateCompound(parent, childrenByCompound, { parent, a: aDone })
    ).toBe(true);
  });

  it('treats an explicit threshold=0 as 1 (no vacuous-true)', () => {
    // Same defense applied to an explicit zero (e.g., a writer that emits 0
    // for "any" semantics) — should not silently mark every M_OF_N complete.
    const parent = compoundTask('parent', OperatorType.M_OF_N, { threshold: 0 });
    const a = task('a', { isCompleted: false });
    const childrenByCompound = { parent: [child('parent', 'a', 0)] };
    const taskById = { parent, a };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(false);
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

// ─── Cycle safety ─────────────────────────────────────────────────────────────

describe('evaluateCompound — cycle safety', () => {
  it('breaks A→B→A self-cycle without stack overflow (AND-of-cycle = false)', () => {
    // Malformed graph: parent A's child is B; B's child is A. Could occur via
    // a sync of malformed remote data even though normal write paths block
    // direct self-reference.
    const a = compoundTask('a', OperatorType.AND);
    const b = compoundTask('b', OperatorType.AND);
    const childrenByCompound = {
      a: [child('a', 'b', 0)],
      b: [child('b', 'a', 0)],
    };
    const taskById = { a, b };
    // A's only child is B. B's only child is A — back-edge resolves to false.
    // So B is AND of [false] → false. So A is AND of [false] → false.
    expect(evaluateCompound(a, childrenByCompound, taskById)).toBe(false);
    expect(evaluateCompound(b, childrenByCompound, taskById)).toBe(false);
  });

  it('breaks 3-node cycle A→B→C→A deterministically', () => {
    const a = compoundTask('a', OperatorType.AND);
    const b = compoundTask('b', OperatorType.AND);
    const c = compoundTask('c', OperatorType.AND);
    const childrenByCompound = {
      a: [child('a', 'b', 0)],
      b: [child('b', 'c', 0)],
      c: [child('c', 'a', 0)],
    };
    const taskById = { a, b, c };
    expect(evaluateCompound(a, childrenByCompound, taskById)).toBe(false);
  });

  it('cycle visit-set is per-call: parent with two unrelated branches still evaluates correctly after each branch resolves', () => {
    // visiting must be cleared on the way back up the recursion stack (not
    // accumulated across siblings) — otherwise sibling branches would falsely
    // see each other as cycles.
    const parent = compoundTask('parent', OperatorType.AND);
    const branchA = compoundTask('branchA', OperatorType.AND);
    const branchB = compoundTask('branchB', OperatorType.AND);
    const leafA = task('leafA', { isCompleted: true });
    const leafB = task('leafB', { isCompleted: true });
    const childrenByCompound = {
      parent: [child('parent', 'branchA', 0), child('parent', 'branchB', 1)],
      branchA: [child('branchA', 'leafA', 0)],
      branchB: [child('branchB', 'leafB', 0)],
    };
    const taskById = { parent, branchA, branchB, leafA, leafB };
    expect(evaluateCompound(parent, childrenByCompound, taskById)).toBe(true);
  });
});
