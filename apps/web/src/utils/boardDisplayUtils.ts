import { BoardStatus, Timeframe, isTimeframeExpired } from '@oybc/shared';

/**
 * Returns a human-readable label for a board status.
 *
 * @param status - The BoardStatus value
 * @returns "ACTIVE", "COMPLETED", or "DRAFT"
 */
export function statusLabel(status: BoardStatus | string): string {
  if (status === BoardStatus.ACTIVE) return 'ACTIVE';
  if (status === BoardStatus.COMPLETED) return 'COMPLETED';
  if (status === BoardStatus.ARCHIVED) return 'ARCHIVED';
  if (status === BoardStatus.DRAFT) return 'DRAFT';
  return String(status).toUpperCase();
}

/**
 * Returns whether a board is expired (past its end date and not Custom timeframe).
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
