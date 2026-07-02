import { BoardStatus, Timeframe, isTimeframeExpired } from '@oybc/shared';

/**
 * Returns a human-readable label for a board status.
 *
 * @param status - The BoardStatus value
 * @returns "ACTIVE", "COMPLETED", "ARCHIVED", or "DRAFT"; unknown values are uppercased
 */
export function statusLabel(status: BoardStatus | string): string {
  if (status === BoardStatus.ACTIVE) return 'ACTIVE';
  if (status === BoardStatus.COMPLETED) return 'COMPLETED';
  if (status === BoardStatus.ARCHIVED) return 'ARCHIVED';
  if (status === BoardStatus.DRAFT) return 'DRAFT';
  return String(status).toUpperCase();
}

/**
 * Returns whether a board is expired (past its end date).
 *
 * Custom timeframe boards are never considered expired — they have user-specified
 * dates but no enforced deadline (by design, per SYNC_STRATEGY.md).
 *
 * @param board - Object with timeframe and endDate fields
 * @returns true if the board's deadline has passed
 */
export function isBoardExpired(board: { timeframe: string; endDate?: string }): boolean {
  if (board.timeframe === Timeframe.CUSTOM) return false;
  if (!board.endDate) return false;
  return isTimeframeExpired(board.endDate);
}

/**
 * Returns whether an active board's end date is within the next 24 hours but
 * has not yet passed.
 *
 * Mirrors iOS `isBoardExpiringSoon(_:)` in `BoardListView.swift`. Only fires
 * for ACTIVE boards with a non-custom, non-indefinite timeframe and a valid
 * endDate — all other boards return false.
 *
 * @param board - Object with status, timeframe, and endDate fields
 * @returns true when endDate is in [now, now + 24h)
 */
export function isBoardExpiringSoon(board: {
  status: string;
  timeframe: string;
  endDate?: string;
}): boolean {
  if (board.status !== BoardStatus.ACTIVE) return false;
  if (board.timeframe === Timeframe.CUSTOM) return false;
  // Mirror isBoardIndefinite: INDEFINITE timeframe or absent endDate = never expires.
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return false;
  const end = new Date(board.endDate).getTime();
  if (!Number.isFinite(end)) return false;
  const msLeft = end - Date.now();
  return msLeft >= 0 && msLeft < 24 * 60 * 60 * 1000;
}

/**
 * Returns a human-readable expiry indicator for a board.
 *
 * @param board - Object with timeframe and endDate fields
 * @returns "No deadline", "Expired", "Expires today", "1 day left", or "N days left"
 */
export function getExpiryLabel(board: { timeframe: string; endDate?: string }): string {
  if (board.timeframe === Timeframe.CUSTOM) return 'No deadline';
  if (!board.endDate) return 'No deadline';
  if (isTimeframeExpired(board.endDate)) return 'Expired';
  const endTime = new Date(board.endDate).getTime();
  if (!Number.isFinite(endTime)) return 'No deadline';
  const msLeft = endTime - Date.now();
  const daysLeft = Math.ceil(msLeft / (1000 * 60 * 60 * 24));
  if (daysLeft <= 0) return 'Expires today';
  if (daysLeft === 1) return '1 day left';
  return `${daysLeft} days left`;
}
