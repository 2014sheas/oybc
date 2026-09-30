import { Timeframe, type WeekStartDay } from '@oybc/shared';

/**
 * Pure caption for WHEN a repeating board renews, derived from its cadence
 * timeframe + the user's week-start preference (Profile reorg PR3,
 * `design_handoff_profile_reorg/README.md` §4 "Board settings"). Used by
 * `formatRepeatingBoardMeta` below; exported separately so both platforms'
 * unit tests can pin the per-timeframe strings directly.
 *
 * Recurring boards exclude `CUSTOM`/`INDEFINITE` (`PARENT_TIMEFRAMES`,
 * `docs/ARCHITECTURE.md` §Phase 6) — the `default` branch below is
 * unreachable in production but keeps the switch exhaustive for the wider
 * `Timeframe` enum type.
 *
 * @param timeframe - The repeating board's cadence.
 * @param weekStartDay - The user's week-start preference; only affects the
 *   WEEKLY caption (a weekly board renews ON the week-start day).
 * @returns e.g. `"renews Mondays"`, `"renews daily"`, `"renews the 1st"`.
 */
export function formatRenewsCaption(timeframe: Timeframe, weekStartDay: WeekStartDay): string {
  switch (timeframe) {
    case Timeframe.DAILY:
      return 'renews daily';
    case Timeframe.WEEKLY:
      return weekStartDay === 'sunday' ? 'renews Sundays' : 'renews Mondays';
    case Timeframe.MONTHLY:
      return 'renews the 1st';
    case Timeframe.YEARLY:
      return 'renews Jan 1';
    case Timeframe.CUSTOM:
    case Timeframe.INDEFINITE:
      return 'renews'; // unreachable — repeating boards exclude these
  }
}

/**
 * One-line meta caption for a compact repeating-board row: `"{size}×{size}
 * board · {n}-task pool · renews {day}"`, or `"… · paused"` in place of the
 * renewal clause when the board is paused (owner decision,
 * `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md` PR3
 * paragraph — the design's `4c-board-settings.png` shows "paused" replacing
 * the renewal clause outright, not appending to it).
 *
 * @param boardSize - 3, 4, or 5.
 * @param taskCount - The board's CURRENT resolved mix size (not the raw
 *   `seedTaskIds.length` — see `RepeatingBoardRowProps.taskCount`).
 * @param timeframe - The repeating board's cadence.
 * @param weekStartDay - The user's week-start preference.
 * @param isActive - Whether the repeating board is active (vs. paused).
 * @returns The full meta line.
 */
export function formatRepeatingBoardMeta(
  boardSize: number,
  taskCount: number,
  timeframe: Timeframe,
  weekStartDay: WeekStartDay,
  isActive: boolean,
): string {
  const sizePart = `${boardSize}×${boardSize} board`;
  const taskPart = `${taskCount}-task pool`;
  const statusPart = isActive ? formatRenewsCaption(timeframe, weekStartDay) : 'paused';
  return `${sizePart} · ${taskPart} · ${statusPart}`;
}
