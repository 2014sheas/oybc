import type { Task, CompoundChild } from '../types';
import { OperatorType, TaskType } from '../constants/enums';

/**
 * Evaluate whether a compound Task is complete.
 *
 * Pure: takes pre-fetched maps, performs no I/O.
 * Recurses into nested compounds, with cycle detection.
 * Treats soft-deleted children as absent.
 * Treats unresolvable childTaskIds (not in `taskById`) as `false`.
 *
 * For non-compound Tasks (defensive callers), returns `task.isCompleted`
 * directly — this lets the function be used as a uniform "is this Task
 * done?" lookup regardless of type.
 *
 * **Cycle handling.** A `compoundChildren` cycle (e.g., A→B→A) can in
 * principle land via sync of malformed data. If evaluation hits a compound
 * already on the recursion stack, the back-edge is treated as `false` for
 * that branch (and the rest of the operator evaluates normally). This is
 * deterministic, bounded, and never throws — preferred to a stack overflow
 * that would brick board derivation across the entire workspace.
 *
 * @param compound          The Task to evaluate. If `type !== 'compound'`,
 *                          returns `compound.isCompleted` directly.
 * @param childrenByCompound Map of `compoundTaskId` → list of CompoundChild rows.
 * @param taskById           Map of `taskId` → Task. Used to resolve child state.
 *                           Children whose taskId is missing from this map
 *                           evaluate as `false`.
 * @returns `true` if the compound's operator condition is satisfied.
 */
export function evaluateCompound(
  compound: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
): boolean {
  return evaluateCompoundInner(compound, childrenByCompound, taskById, new Set());
}

function evaluateCompoundInner(
  compound: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  visiting: Set<string>,
): boolean {
  if (compound.type !== TaskType.COMPOUND) {
    return compound.isCompleted;
  }

  // Cycle guard: if we've already entered this compound on the recursion
  // stack, the back-edge resolves to `false` for this branch.
  if (visiting.has(compound.id)) return false;
  visiting.add(compound.id);

  const links = (childrenByCompound[compound.id] ?? []).filter((c) => !c.isDeleted);
  const childStates: boolean[] = links.map((link) => {
    const child = taskById[link.childTaskId];
    if (!child || child.isDeleted) return false;
    if (child.type === TaskType.COMPOUND) {
      return evaluateCompoundInner(child, childrenByCompound, taskById, visiting);
    }
    return child.isCompleted;
  });

  visiting.delete(compound.id);

  switch (compound.operator) {
    case OperatorType.AND:
      // Vacuous truth: a compound with zero children is treated as complete.
      // This matches set-theoretic AND-of-empty semantics and avoids surprising
      // an editor mid-restructure with a permanently-incomplete parent.
      return childStates.length === 0 || childStates.every(Boolean);
    case OperatorType.OR:
      return childStates.some(Boolean);
    case OperatorType.M_OF_N:
      return childStates.filter(Boolean).length >= (compound.threshold ?? 0);
    default:
      // Operator missing on a compound row — treat as incomplete (a Zod
      // validation error should have surfaced before we got here).
      return false;
  }
}
