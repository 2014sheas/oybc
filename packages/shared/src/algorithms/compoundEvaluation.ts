import type { Task, CompoundChild } from '../types';
import { OperatorType, TaskType } from '../constants/enums';
import {
  resolveTaskWindowState,
  isEventOwningTask,
  type CompoundWindowContext,
} from './taskEvents';

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
 * **Windowed evaluation (Windowed Completion, PR A).** When `windowContext`
 * is supplied, primitive children resolve against the host board's window via
 * `resolveTaskWindowState` instead of reading the lifetime `isCompleted` cache;
 * derived (shared-counter-linked) counting children fall back to their cache
 * (the carve-out); nested compounds inherit the SAME window (host-window
 * inheritance). When `windowContext` is omitted the behavior is byte-identical
 * to before — the lifetime default that keeps every existing caller unchanged.
 *
 * @param compound          The Task to evaluate. If `type !== 'compound'`,
 *                          returns `compound.isCompleted` directly.
 * @param childrenByCompound Map of `compoundTaskId` → list of CompoundChild rows.
 * @param taskById           Map of `taskId` → Task. Used to resolve child state.
 *                           Children whose taskId is missing from this map
 *                           evaluate as `false`.
 * @param windowContext      Optional. When present, switches primitive-child
 *                           resolution to windowed events (see above).
 * @returns `true` if the compound's operator condition is satisfied.
 */
export function evaluateCompound(
  compound: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  windowContext?: CompoundWindowContext,
): boolean {
  return evaluateCompoundInner(compound, childrenByCompound, taskById, new Set(), windowContext);
}

/**
 * Resolve a single primitive (non-compound) child's completion, honoring the
 * window context when present. Derived-counting children are carved out (read
 * their lifetime cache); every other event-owning primitive resolves windowed.
 */
function resolvePrimitiveChildState(
  child: Task,
  windowContext: CompoundWindowContext | undefined,
): boolean {
  if (!windowContext) return child.isCompleted;
  // Derived-task carve-out: shared-counter-linked counting children keep their
  // propagation-stamped lifetime cache — they don't own events.
  if (!isEventOwningTask(child)) return child.isCompleted;
  const events = windowContext.eventsByTaskId[child.id] ?? [];
  return resolveTaskWindowState(child, events, windowContext.windowStart).isCompleted;
}

function evaluateCompoundInner(
  compound: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  visiting: Set<string>,
  windowContext: CompoundWindowContext | undefined,
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
      // Nested compounds inherit the same host window.
      return evaluateCompoundInner(child, childrenByCompound, taskById, visiting, windowContext);
    }
    return resolvePrimitiveChildState(child, windowContext);
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
    case OperatorType.M_OF_N: {
      // Floor threshold at 1. A missing/null threshold (?? 0) or an explicit 0
      // would produce vacuous-true (`0 >= 0`) and silently mark the compound
      // complete with zero work done — which can happen when migrated legacy
      // composites lack an explicit M_OF_N threshold (see migrationHelpers
      // skip path). Treat threshold as `max(1, threshold ?? 1)` so a malformed
      // row at worst behaves like an OR (one child satisfies it) rather than
      // always-complete.
      const required = Math.max(1, compound.threshold ?? 1);
      return childStates.filter(Boolean).length >= required;
    }
    default:
      // Operator missing on a compound row — treat as incomplete (a Zod
      // validation error should have surfaced before we got here).
      return false;
  }
}

/**
 * Clamp a compound "at least N" (M_OF_N) threshold into the valid **stored**
 * range `[1, max(1, childCount)]`.
 *
 * Pure and platform-shared: this is the single source of truth for the
 * threshold clamp that both web and iOS apply before persisting a compound.
 * It replaces ~8 hand-rolled `min(max(1, t), max(1|2, count))` clamps that had
 * drifted apart on the upper-bound floor (`max(1)` vs `max(2)`), which could
 * store a different threshold across platforms for edge child-counts.
 *
 * Semantics:
 * - lower bound 1 — a threshold below 1 would make M_OF_N vacuously true
 *   (matches `evaluateCompound`'s `max(1, threshold)` floor);
 * - upper bound `max(1, childCount)` — a threshold can't exceed the real child
 *   count; the `max(1, …)` avoids a degenerate empty range when `childCount`
 *   is 0 (a compound mid-build with no children yet);
 * - non-integer input is truncated toward zero before clamping.
 *
 * The stepper's *display* max (a UI affordance that may sit above the stored
 * ceiling while the user is still adding sub-tasks) is a separate concern and
 * is not this function's job.
 */
export function clampCompoundThreshold(threshold: number, childCount: number): number {
  const maxN = Math.max(1, childCount);
  return Math.min(Math.max(1, Math.trunc(threshold)), maxN);
}
