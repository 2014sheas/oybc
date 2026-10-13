import { BoardStatus, Timeframe } from '../constants/enums';

/**
 * "Expiring" board tag — when an active board is close enough to its end to
 * flag it (owner ruling 2026-10-13). The lead time scales with the board's
 * timeframe; a flat 24 h window tagged every daily board for its whole life.
 *
 * Swift twin: `apps/ios/OYBC/Helpers/BoardExpiry.swift`; both run
 * `tests/fixtures/boardExpiryVectors.json`.
 */

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

/** Lead time before `endDate` at which each core timeframe reads "Expiring". */
export const EXPIRING_SOON_LEAD_MS = {
  [Timeframe.DAILY]: 3 * HOUR_MS,
  [Timeframe.WEEKLY]: DAY_MS,
  [Timeframe.MONTHLY]: 3 * DAY_MS,
  [Timeframe.YEARLY]: 14 * DAY_MS,
} as const;

/** A custom board's lead time is this share of its own length… */
export const CUSTOM_EXPIRING_SOON_FRACTION = 0.1;
/** …clamped to [min, max] (min matches daily, max matches yearly). */
export const CUSTOM_EXPIRING_SOON_MIN_MS = 3 * HOUR_MS;
export const CUSTOM_EXPIRING_SOON_MAX_MS = 14 * DAY_MS;

/** The Board fields the expiring tag reads. */
export interface ExpiringBoardFields {
  status: string;
  timeframe: string;
  startDate?: string;
  endDate?: string;
}

/**
 * The lead time before `endDate` at which this board reads "Expiring".
 *
 * @param board - timeframe + window dates
 * @returns milliseconds, or `null` for a board that never expires
 *   (indefinite / no or unparseable `endDate`)
 */
export function expiringSoonLeadMs(board: Omit<ExpiringBoardFields, 'status'>): number | null {
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return null;
  const end = new Date(board.endDate).getTime();
  if (!Number.isFinite(end)) return null;
  switch (board.timeframe) {
    case Timeframe.DAILY:
    case Timeframe.WEEKLY:
    case Timeframe.MONTHLY:
    case Timeframe.YEARLY:
      return EXPIRING_SOON_LEAD_MS[board.timeframe];
    default: {
      const start = board.startDate ? new Date(board.startDate).getTime() : NaN;
      const length = Number.isFinite(start) ? end - start : NaN;
      const lead = Number.isFinite(length) && length > 0
        ? length * CUSTOM_EXPIRING_SOON_FRACTION
        : CUSTOM_EXPIRING_SOON_MIN_MS;
      return Math.min(CUSTOM_EXPIRING_SOON_MAX_MS, Math.max(CUSTOM_EXPIRING_SOON_MIN_MS, lead));
    }
  }
}

/**
 * Whether an active board is inside its "Expiring" lead time: its end is
 * still ahead of `nowMs` but within `expiringSoonLeadMs`.
 *
 * @param board - status, timeframe and window dates
 * @param nowMs - the screen's pinned instant (never a fresh clock read)
 * @returns true when `0 <= end - now < lead`
 */
export function isBoardExpiringSoon(board: ExpiringBoardFields, nowMs: number): boolean {
  if (board.status !== BoardStatus.ACTIVE) return false;
  const lead = expiringSoonLeadMs(board);
  if (lead == null || !board.endDate) return false;
  const msLeft = new Date(board.endDate).getTime() - nowMs;
  return msLeft >= 0 && msLeft < lead;
}
