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
 * A custom-timeframe board with a user-specified end date expires at that date
 * just like a timed board — the seal/backstop logic already treats it as a
 * closeable window (`isBoardSealable` only excludes INDEFINITE), so the display
 * must agree. Only INDEFINITE / no-endDate boards are never expired.
 *
 * @param board - Object with timeframe and endDate fields
 * @returns true if the board's deadline has passed
 */
export function isBoardExpired(board: { timeframe: string; endDate?: string }): boolean {
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return false;
  return isTimeframeExpired(board.endDate);
}

/**
 * Boards-list filter-chip predicate (All / Active / Completed / Draft),
 * shared by `BoardsPage` and pinned by unit tests — mirror of iOS
 * `boardMatchesListFilter(_:filter:)` in `TimeframeFormatting.swift`.
 *
 * - `'all'` — every board.
 * - `'completed'` — every board whose run is over: status COMPLETED
 *   (greenlog), PLUS ACTIVE boards that are sealed or expired. A
 *   sealed-but-incomplete board keeps status ACTIVE forever by design
 *   (the F3 sealing rule), so status alone can't classify it. Card badges
 *   (Closed / Expired / Completed) distinguish how each board finished.
 * - `'active'` — ACTIVE boards still in play (not sealed, not expired).
 * - anything else (`'draft'`) — exact status match.
 *
 * @param board - Object with status, timeframe, endDate, and sealedAt fields
 * @param filter - The selected chip value
 * @returns true when the board belongs under the given chip
 */
export function boardMatchesListFilter(
  board: { status: string; timeframe: string; endDate?: string; sealedAt?: string | null },
  filter: string
): boolean {
  if (filter === 'all') return true;
  const ended = board.sealedAt != null || isBoardExpired(board);
  if (filter === BoardStatus.COMPLETED) {
    return board.status === BoardStatus.COMPLETED || (board.status === BoardStatus.ACTIVE && ended);
  }
  if (board.status !== filter) return false;
  if (filter === BoardStatus.ACTIVE && ended) return false;
  return true;
}

/**
 * Returns whether an active board's end date is within the next 24 hours but
 * has not yet passed.
 *
 * Mirrors iOS `isBoardExpiringSoon(_:)` in `BoardListView.swift`. Only fires
 * for ACTIVE boards with a valid endDate that isn't INDEFINITE — custom boards
 * with an end date are included (they expire/seal like timed boards).
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
  // INDEFINITE timeframe or absent endDate = never expires.
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
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return 'No deadline';
  if (isTimeframeExpired(board.endDate)) return 'Expired';
  const endTime = new Date(board.endDate).getTime();
  if (!Number.isFinite(endTime)) return 'No deadline';
  const msLeft = endTime - Date.now();
  const daysLeft = Math.ceil(msLeft / (1000 * 60 * 60 * 24));
  if (daysLeft <= 0) return 'Expires today';
  if (daysLeft === 1) return '1 day left';
  return `${daysLeft} days left`;
}
