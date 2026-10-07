/**
 * memberRuleTargets.ts — the target arithmetic of Board Sources member rules
 * (docs/BOARD_SOURCES.md §Member rules → §Target math): the nominal window
 * length of a timeframe, the pro-rated auto target, the vary (dice) range and
 * its seeded roll — each stepping in the member's count kind (whole units, or
 * tenths for continuous; docs/COUNTER_KINDS.md §3).
 *
 * Split out of `memberRules.ts` to keep that file under the 1000-line
 * god-file guardrail; `memberRules.ts` re-exports every symbol here, so the
 * public surface (and the `@oybc/shared` barrel) is unchanged. Swift twin:
 * the same functions on `BoardSources` in `BoardSourceMemberRules.swift`,
 * pinned by `tests/fixtures/memberRuleVectors.json`.
 */

import { Timeframe } from '../constants/enums';
import type { VaryLevel } from '../types/boardSource';
import { ceilToCountStep, countTargetStep, isWholeCountKind, quantizeCount, roundToCountStep } from './countValue';
import type { CountKind } from './countValue';

/**
 * UTC day index of an ISO date's `YYYY-MM-DD` prefix.
 *
 * @param iso - An ISO8601 date or date-time string.
 * @returns Whole days since the epoch, or `null` if the prefix doesn't parse.
 */
function dayNumber(iso: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return null;
  return Math.floor(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86_400_000);
}

/**
 * Nominal length of a timeframe window in days. CUSTOM = inclusive calendar
 * span of the `YYYY-MM-DD` prefixes (UTC arithmetic — never local-time
 * subtraction, so a DST boundary inside the span can't shave or add a day);
 * INDEFINITE, or CUSTOM with a missing/unparseable bound, = `null`.
 *
 * @param timeframe - The window's timeframe.
 * @param startDate - CUSTOM only: the window's inclusive first day.
 * @param endDate - CUSTOM only: the window's inclusive last day.
 * @returns The nominal day count, or `null` when it is not knowable.
 */
export function nominalWindowDays(
  timeframe: Timeframe,
  startDate?: string | null,
  endDate?: string | null
): number | null {
  switch (timeframe) {
    case Timeframe.DAILY:
      return 1;
    case Timeframe.WEEKLY:
      return 7;
    case Timeframe.MONTHLY:
      return 30;
    case Timeframe.YEARLY:
      return 365;
    case Timeframe.CUSTOM: {
      if (!startDate || !endDate) return null;
      const a = dayNumber(startDate);
      const b = dayNumber(endDate);
      if (a === null || b === null) return null;
      return Math.max(1, b - a + 1);
    }
    default:
      return null;
  }
}

/**
 * Auto target for a counting member pulled from a board source onto a board
 * with a different window: the member's goal pro-rated by the window ratio,
 * rounded up, never above the goal itself (docs/BOARD_SOURCES.md §Target math).
 *
 * Four explicit branches in order: unknown source window, unknown target
 * window, a target window at least as long as the source's (no shrink), else
 * the pro-rated ceiling — to the kind's step (whole units, or 0.1 for
 * continuous: 26.2 mi monthly → weekly = 6.2).
 *
 * @param goal - The member's own `maxCount` (≥ 1 whole, > 0 continuous).
 * @param sourceDays - Nominal days of the source board's window, or `null`.
 * @param targetDays - Nominal days of the board being assembled, or `null`.
 * @param kind - The member's count kind (default `'discrete'`).
 * @returns The auto target (one step ≥, ≤ `goal`).
 */
export function autoTarget(
  goal: number,
  sourceDays: number | null,
  targetDays: number | null,
  kind: CountKind = 'discrete'
): number {
  if (sourceDays === null) return goal;
  if (targetDays === null) return goal;
  if (targetDays >= sourceDays) return goal;
  return Math.min(goal, ceilToCountStep((goal * targetDays) / sourceDays, kind));
}

/** Vary level → the fraction of `t` the roll may move in either direction. */
const VARY_P: Record<VaryLevel, number> = { 0: 0, 1: 0.2, 2: 0.5 };

/**
 * Inclusive `[lo, hi]` a rolled target may land in: symmetric ± `p` around the
 * target (docs/BOARD_SOURCES.md §Member rules — "a little" = ±20 %, "a lot" =
 * ±50 %). `t` is clamped to `1…goal` first (the stepper is goal-capped) and
 * `lo` never drops below 1, but `hi` has NO ceiling — a roll may land above
 * the target by up to `+p`, so a goal-10 member on "a little" rolls inside
 * `[8, 12]`. Overshooting the goal is a feature: `currentCount > maxCount` is
 * valid in this product. (Fixed 2026-10-06 — the first implementation capped
 * `hi` at the goal and only ever lowered.) "1" here is the kind's step: a
 * continuous member clamps and rounds in tenths (6.1 on "a little" →
 * `[4.9, 7.3]`). Only COMPUTED bounds are stepped (R17): a continuous
 * member's dice off — or a range that collapses — keeps `t` as-is, so an
 * off-step goal like 26.25 or 0.05 is never rewritten.
 *
 * @param t - The pre-vary target.
 * @param level - Vary level (0 = off).
 * @param goal - The member's own `maxCount`; clamps `t`, never `hi`.
 * @param kind - The member's count kind (default `'discrete'`).
 * @returns The inclusive `[lo, hi]` pair.
 */
export function varyRange(
  t: number,
  level: VaryLevel,
  goal: number,
  kind: CountKind = 'discrete'
): [number, number] {
  const step = countTargetStep(kind);
  const tc = Math.min(Math.max(step, t), goal);
  const p = VARY_P[level];
  const lo = Math.max(step, roundToCountStep(tc * (1 - p), kind));
  // `lo <= hi` holds for every `goal >= step` (the only reachable input); the
  // `max` only keeps a malformed smaller goal from inverting the range, so
  // both twins then return a degenerate range and consume no rng.
  const hi = Math.max(lo, roundToCountStep(tc * (1 + p), kind));
  if (!isWholeCountKind(kind) && (p === 0 || lo === hi)) return [quantizeCount(tc), quantizeCount(tc)];
  return [lo, hi];
}

/**
 * Uniform roll over the kind's steps inside {@link varyRange} (`n + 1`
 * values `lo, lo + step, …, hi`). Level 0 never touches `rng`, and neither
 * does a degenerate range (`lo === hi`); otherwise exactly ONE sample — which
 * is what keeps a seeded sequence reproducible across platforms.
 *
 * @param t - The pre-vary target.
 * @param level - Vary level (0 = off).
 * @param goal - The member's own `maxCount`; clamps `t` (see {@link varyRange}).
 * @param rng - Uniform `[0, 1)` source; consumed at most once.
 * @param kind - The member's count kind (default `'discrete'`).
 * @returns The rolled target (a step multiple in `[lo, hi]`).
 */
export function rollTarget(
  t: number,
  level: VaryLevel,
  goal: number,
  rng: () => number,
  kind: CountKind = 'discrete'
): number {
  const [lo, hi] = varyRange(t, level, goal, kind);
  if (level === 0 || lo === hi) return lo;
  const step = countTargetStep(kind);
  const n = Math.round((hi - lo) / step);
  return quantizeCount(lo + Math.floor(rng() * (n + 1)) * step);
}
