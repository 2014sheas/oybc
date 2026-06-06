/**
 * sharedCounter.ts — Shared-counter math helpers (Phase 1 + Phase 3).
 *
 * Phase 1: `deriveDisplayedCount` — snapshot math for the derived display.
 * Phase 3: `propagateIncrement` — pure propagation result for writing back
 *   to derived tasks after a source increment. The DB layer owns the writes.
 *
 * Computes the displayed count and completion status for a derived counting
 * task that shares a source task's running total via `sharedCounterId`.
 *
 * Design decisions locked in ARCHITECTURE.md § "Shared counters (Issue #84 — Phase 0 design)":
 *  - Decision 2: The source task's `currentCount` is the accumulator; derived
 *    tasks never have their own count written — they derive display values.
 *  - Decision 6: `baseline` is the value of `source.currentCount` at the
 *    moment the derived task was linked. "Start from zero" mode sets
 *    `baseline = source.currentCount_at_link_time`. "Inherit" mode sets
 *    `baseline = 0`.
 *
 * Invariants:
 *  - LOW-END CLAMP: `displayed` is clamped to a minimum of 0 via `Math.max(0, ...)`.
 *    A source count below the baseline (shouldn't happen in practice, but defensive)
 *    yields 0 rather than a negative displayed value.
 *  - NO HIGH-END CLAMP: if `source.currentCount = 5500`, `baseline = 0`, and
 *    `maxCount = 5000`, then `displayed = 5500` and `isCompleted = true`.
 *    The Phase 0 doc explicitly forbids a `Math.min(displayed, maxCount)` clamp —
 *    overshoot is intentional and must be visible to the user.
 *  - ONE-WAY LATCH: once `isCompleted` is `true` on a linked task, it stays
 *    `true`. Re-deriving with a source count that would yield `false` does NOT
 *    un-complete the task. Resetting requires explicit user action (not in
 *    Phase 3 scope). The latch is enforced by `propagateIncrement` which
 *    accepts the task's existing `isCompleted` flag and never flips it from
 *    `true` to `false`.
 *
 * This TypeScript implementation is the source of truth. A manual Swift port
 * lives in `apps/ios/OYBC/Helpers/SharedCounter.swift` and must be mirrored
 * on any math change to avoid cross-platform divergence.
 */

/**
 * Derives the displayed count and completion snapshot for a derived counting task.
 *
 * @param derivedTask - Minimal slice of the derived task: `baseline` (the
 *   source count at link time; 0 means "inherit from zero") and `maxCount`
 *   (the derived task's personal threshold).
 * @param source - Minimal slice of the source task: `currentCount` (the
 *   live running total that drives the derived display).
 * @returns `{ displayed, isCompleted }` — a snapshot. `displayed` is the
 *   count relative to `baseline`; `isCompleted` is `true` when
 *   `displayed >= maxCount`. Neither value is written to the DB in Phase 1;
 *   the write happens in Phase 3 when `runBoardCascadeForTask` is extended.
 */
export function deriveDisplayedCount(
  derivedTask: { baseline?: number; maxCount?: number },
  source: { currentCount?: number },
): { displayed: number; isCompleted: boolean } {
  const baseline = derivedTask.baseline ?? 0;
  const maxCount = derivedTask.maxCount ?? 0;
  const sourceCount = source.currentCount ?? 0;

  // LOW-END CLAMP ONLY: displayed may never go below 0.
  // NO Math.min(...) — high-end overshoot is intentional and visible.
  const displayed = Math.max(0, sourceCount - baseline);

  // isCompleted when the derived task's personal threshold is met.
  // maxCount === 0 means the task is immediately complete (you cannot
  // be below zero progress toward a zero target).
  const isCompleted = displayed >= maxCount;

  return { displayed, isCompleted };
}

// ─── Phase 3: propagation result ─────────────────────────────────────────────

/**
 * Minimal slice of the source task as needed by `propagateIncrement`.
 */
export interface PropagateIncrementSource {
  /** The live running total AFTER the increment has been applied. */
  currentCount: number;
}

/**
 * Minimal slice of one linked (derived) task as needed by `propagateIncrement`.
 */
export interface PropagateIncrementLinkedTask {
  id: string;
  /** The baseline offset for this linked task (0 = inherit). */
  baseline?: number | null;
  /** This linked task's personal threshold. */
  maxCount?: number | null;
  /**
   * The task's current persisted `isCompleted` value BEFORE this increment.
   * One-way latch: if already `true`, the result keeps it `true` even if the
   * freshly derived value would return `false` (shouldn't happen in practice
   * since source count only goes up on an increment, but defensive).
   */
  isCompleted: boolean;
}

/**
 * The new state to write for one linked task after a source increment.
 */
export interface LinkedTaskIncrementResult {
  taskId: string;
  /** New `currentCount` to store on the linked task (mirrors source's new count
   *  so cascade readers see the same number without re-deriving). */
  newCurrentCount: number;
  /**
   * New `isCompleted` to store. One-way latch — never transitions from `true`
   * to `false`. May transition `false` → `true` when the derived displayed
   * value first reaches or exceeds `maxCount`.
   */
  newIsCompleted: boolean;
  /**
   * The derived display value (= `source.currentCount - baseline`, clamped to
   * 0). Useful for the caller to pass to the cascade display layer without a
   * second `deriveDisplayedCount` call.
   */
  displayed: number;
}

/**
 * Pure propagation helper for Phase 3's increment hot-path.
 *
 * Given the source task's new `currentCount` (AFTER the increment) and an
 * array of all linked (derived) tasks, returns the new `currentCount` and
 * `isCompleted` to write for each linked task — one entry per linked task.
 *
 * Invariants enforced:
 *  - NO HIGH-END CLAMP on source: callers must never clamp `sourceAfter.currentCount`
 *    before passing it in. This function does not touch the source count.
 *  - ONE-WAY LATCH: if `linked.isCompleted` is already `true`, the result
 *    keeps `newIsCompleted = true` regardless of the derived value.
 *  - LOW-END CLAMP on display: `displayed` is never negative.
 *  - Tasks with no `maxCount` (null/undefined/0) are immediately complete
 *    (same rule as `deriveDisplayedCount`).
 *
 * Pure function — no DB calls, no side effects. The DB layer owns writes.
 *
 * @param sourceAfter - Source task state AFTER the increment (only `currentCount`
 *   is read).
 * @param linkedTasks - All tasks whose `sharedCounterId` === source task id.
 *   Pass only non-deleted tasks.
 * @returns One `LinkedTaskIncrementResult` per entry in `linkedTasks`, in the
 *   same order.
 */
export function propagateIncrement(
  sourceAfter: PropagateIncrementSource,
  linkedTasks: readonly PropagateIncrementLinkedTask[],
): LinkedTaskIncrementResult[] {
  return linkedTasks.map((linked) => {
    const { displayed, isCompleted: derivedCompleted } = deriveDisplayedCount(
      { baseline: linked.baseline ?? 0, maxCount: linked.maxCount ?? 0 },
      { currentCount: sourceAfter.currentCount },
    );

    // ONE-WAY LATCH: once true, always true.
    const newIsCompleted = linked.isCompleted || derivedCompleted;

    return {
      taskId: linked.id,
      // Mirror the source's current count so the linked task row carries the
      // same accumulator value. Cascade readers don't need to look up the
      // source; they can just read this task's currentCount and call
      // deriveDisplayedCount with the baseline.
      newCurrentCount: sourceAfter.currentCount,
      newIsCompleted,
      displayed,
    };
  });
}
