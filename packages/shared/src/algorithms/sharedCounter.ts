/**
 * sharedCounter.ts — Phase 1 playground spike math helper.
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
 *
 * Swift source-of-truth: this function has a manual port in
 * `apps/ios/OYBC/Algorithms/SharedCounter.swift`. Any change to the math here
 * must be mirrored there to avoid cross-platform divergence.
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
