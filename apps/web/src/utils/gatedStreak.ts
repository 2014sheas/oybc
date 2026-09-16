import { computeStreak, type AchievementTrigger, type Board, type Timeframe, type WeekStartDay } from '@oybc/shared';

/**
 * `computeStreak`, but it refuses to answer before its inputs are known.
 *
 * Late-mutation audit (2026-09-16, shapes B + C): the streak chip was
 * computed from `allBoards` (empty while loading) and `prefs.weekStartDay`
 * (the merged default until `usePreferences` resolves), against a
 * render-time `new Date()`. A Sunday-start user could see one number and
 * then a different one; everyone saw 0 → real. Returning 0 while unready
 * hides the chip rather than showing a figure we'd revise.
 * See `reference_late_mutation_bug_class`.
 *
 * @param ready - prefs (and any board query the caller depends on) resolved
 * @param now - PIN this at the screen (`useMemo`), never a fresh Date per render
 */
export function gatedStreak(
  ready: boolean,
  timeframe: Timeframe,
  trigger: AchievementTrigger,
  boards: Board[],
  weekStartDay: WeekStartDay,
  now: Date,
): number {
  if (!ready) return 0;
  return computeStreak(timeframe, trigger, boards, weekStartDay, now);
}
