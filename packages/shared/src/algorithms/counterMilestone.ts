/**
 * counterMilestone.ts — "Next round-number milestone" helper for a counter's
 * lifetime total (Counters Detail hero + progress bar).
 *
 * Lifted from two drift-prone per-platform copies (web `nextMilestone` in
 * `apps/web/src/pages/CounterDetailPage.tsx`, iOS `milestone` in
 * `Views/ProfileTab/CounterDetailView.swift`) as part of the R2 Counters UX
 * refresh — both call sites now consume this single implementation instead
 * of hand-maintaining the same step list twice. See
 * docs/SHARED_COUNTERS.md §Counters UX refresh.
 *
 * Pure, deterministic: a function of `lifetime` alone.
 */

/**
 * Fixed round-number steps a counter climbs through on its way up. Beyond
 * the top step (100,000), {@link nextCounterMilestone} falls back to the
 * next multiple of 10,000.
 */
const MILESTONE_STEPS: readonly number[] = [
  100, 250, 500, 1000, 2500, 5000, 10_000, 25_000, 50_000, 100_000,
];

/**
 * The next round-number milestone strictly above `lifetime`.
 *
 * Matches both prior per-platform implementations exactly: the first fixed
 * step greater than `lifetime`, or — once past the top fixed step — the
 * next multiple of 10,000 strictly above `lifetime`
 * (`ceil((lifetime + 1) / 10_000) * 10_000`).
 *
 * @param lifetime Non-negative lifetime total (overshoot beyond a task's
 *   own `maxCount` is fine — this helper only cares about the raw number).
 * @returns The next milestone, always strictly greater than `lifetime`.
 */
export function nextCounterMilestone(lifetime: number): number {
  const fixedStep = MILESTONE_STEPS.find((step) => step > lifetime);
  if (fixedStep !== undefined) return fixedStep;
  return Math.ceil((lifetime + 1) / 10_000) * 10_000;
}

/**
 * Progress toward the next milestone, for a progress bar / "N to go" caption.
 */
export interface CounterMilestoneProgress {
  /** The next milestone (see {@link nextCounterMilestone}). */
  next: number;
  /** How much further the counter has to climb to reach `next`. */
  remaining: number;
  /** `lifetime / next`, clamped to `[0, 1]` — a progress-bar fill fraction. */
  fraction: number;
}

/**
 * Derives the next milestone plus remaining/fraction for a progress bar.
 *
 * @param lifetime Non-negative lifetime total.
 * @returns `{ next, remaining, fraction }`. `fraction` is
 *   `min(1, lifetime / next)`; `remaining` is `next - lifetime`.
 */
export function counterMilestoneProgress(lifetime: number): CounterMilestoneProgress {
  const next = nextCounterMilestone(lifetime);
  const remaining = next - lifetime;
  const fraction = Math.min(1, lifetime / next);
  return { next, remaining, fraction };
}
