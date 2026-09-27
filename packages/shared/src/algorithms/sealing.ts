import type { Board } from '../types/board';
import { isBoardIndefinite } from '../types/board';
import { BoardStatus, Timeframe } from '../constants/enums';

/**
 * Windowed Completion — board-sealing detection (pure)
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle + Backstop, §Migration
 * step 3, §Edge cases).
 *
 * These predicates own the "which boards can/should seal" decision so both
 * platforms (and the migration) agree byte-for-byte. The seal transaction
 * itself is platform data-layer code; these are the shared gates it consults.
 */

/** The Board fields the sealing gates read. */
export type SealableBoardFields = Pick<
  Board,
  | 'isDeleted'
  | 'status'
  | 'timeframe'
  | 'startDate'
  | 'endDate'
  | 'sealedAt'
  | 'activatedAt'
  | 'reopenedAt'
>;

/**
 * Whether a board is eligible to seal at all (docs §Lifecycle → Detection):
 * a real, closeable window that isn't already sealed. Excludes:
 *   - soft-deleted boards,
 *   - already-sealed boards (`sealedAt` set — idempotence),
 *   - DRAFT boards (they never seal while drafts),
 *   - indefinite boards (`[startDate, ∞)`, never expire).
 *
 * Archived boards ARE sealable (docs §Edge cases — "Archived boards seal
 * normally"): archived is a `status`, orthogonal to sealing.
 *
 * @param board The board to test (minimal field subset).
 * @returns `true` iff the board could seal (subject to a time gate below).
 */
export function isBoardSealable(board: SealableBoardFields): boolean {
  if (board.isDeleted) return false;
  if (board.sealedAt != null) return false;
  if (board.status === BoardStatus.DRAFT) return false;
  if (isBoardIndefinite(board)) return false;
  return true;
}

/**
 * Whether a board's window has closed and it is awaiting close-out (docs
 * §Lifecycle → Detection: the "closing-out set"). Sealable AND its `endDate`
 * is strictly before `now`. This is the prompt set (the banner UX lands in
 * slice 2); the engine exposes it so both platforms share one definition.
 *
 * @param board The board to test.
 * @param nowMs Current time as epoch ms.
 * @returns `true` iff the board is closed-out but not yet sealed.
 */
export function isBoardClosingOut(board: SealableBoardFields, nowMs: number): boolean {
  if (!isBoardSealable(board)) return false;
  if (board.endDate == null) return false; // (indefinite already excluded)
  return new Date(board.endDate).getTime() < nowMs;
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** Custom-window auto-close grace bounds, in whole local days (D4 / OQ1). */
export const CUSTOM_AUTO_CLOSE_MIN_DAYS = 1;
export const CUSTOM_AUTO_CLOSE_MAX_DAYS = 31;

/**
 * The end of the window AFTER a board's own window, as epoch ms — the
 * "next window of that timeframe" (Board Edit redesign slice 4, D4 / owner
 * ruling R5: yesterday's daily closes at the end of today).
 *
 * Local wall-clock arithmetic on `endDate`'s components (the `stepWindow`
 * convention), so a DST change inside the grace never shifts the result and
 * both platforms agree:
 *   - DAILY   → `endDate` + 1 local day
 *   - WEEKLY  → `endDate` + 7 local days
 *   - MONTHLY → the last day of the month after `endDate`'s month, same wall time
 *   - YEARLY  → Dec 31 of the year after `endDate`'s year, same wall time
 *   - CUSTOM  → `endDate` + the window's own length in whole local days
 *               (rounded), clamped to [1, 31] — the next same-length window,
 *               capped so a long custom board doesn't linger for months (OQ1).
 *
 * @param timeframe The board's timeframe (not INDEFINITE).
 * @param startDate Window start (ISO8601; only CUSTOM reads it).
 * @param end       The parsed `endDate`.
 * @returns Epoch ms of the next window's end.
 */
function nextWindowEndMs(timeframe: Timeframe, startDate: string, end: Date): number {
  const y = end.getFullYear();
  const m = end.getMonth();
  const d = end.getDate();
  const wall = [end.getHours(), end.getMinutes(), end.getSeconds(), end.getMilliseconds()] as const;
  switch (timeframe) {
    case Timeframe.DAILY:
      return new Date(y, m, d + 1, ...wall).getTime();
    case Timeframe.WEEKLY:
      return new Date(y, m, d + 7, ...wall).getTime();
    case Timeframe.MONTHLY:
      // Day 0 of month m+2 = the last day of month m+1 (JS normalises overflow).
      return new Date(y, m + 2, 0, ...wall).getTime();
    case Timeframe.YEARLY:
      return new Date(y + 1, 11, 31, ...wall).getTime();
    default: {
      const lengthDays = Math.round((end.getTime() - new Date(startDate).getTime()) / DAY_MS);
      const graceDays = Math.min(
        CUSTOM_AUTO_CLOSE_MAX_DAYS,
        Math.max(CUSTOM_AUTO_CLOSE_MIN_DAYS, Number.isNaN(lengthDays) ? 0 : lengthDays),
      );
      return new Date(y, m, d + graceDays, ...wall).getTime();
    }
  }
}

/**
 * The absolute auto-close deadline for a board, as epoch ms (Board Edit
 * redesign slice 4, D4 — replaces the old `min(48h, len/4)` backstop): the end
 * of the NEXT window of the board's timeframe (see {@link nextWindowEndMs}).
 *
 * Draft-activated-late anchor: a draft activated AFTER its window ended gets
 * the same grace measured from `activatedAt` —
 * `max(next(endDate), activatedAt + (next(endDate) − endDate))` — so it still
 * gets one full prompt cycle before any silent close.
 *
 * Returns ms (not an ISO string) to sidestep the local-ISO vs UTC encoding
 * question; callers compare `nowMs > deadline`.
 *
 * @param board The board's timeframe + window + activation stamp.
 * @returns Epoch-ms deadline, or `null` when the board never auto-closes
 *   (indefinite / no `endDate` / unparseable `endDate`).
 */
export function computeAutoCloseDeadlineMs(
  board: Pick<Board, 'timeframe' | 'startDate' | 'endDate' | 'activatedAt'>,
): number | null {
  if (isBoardIndefinite(board)) return null;
  const end = new Date(board.endDate as string);
  const endMs = end.getTime();
  if (Number.isNaN(endMs)) return null;
  const nextMs = nextWindowEndMs(board.timeframe, board.startDate, end);
  const activatedMs = board.activatedAt != null ? new Date(board.activatedAt).getTime() : NaN;
  if (Number.isNaN(activatedMs)) return nextMs;
  return Math.max(nextMs, activatedMs + (nextMs - endMs));
}

/**
 * Whether a board is past its auto-close deadline (docs §Lifecycle → auto-close;
 * the name keeps "backstop" to limit churn). Sealable, NOT manually reopened
 * (`reopenedAt` set → never auto-closes, D1), and `now` strictly beyond
 * {@link computeAutoCloseDeadlineMs}.
 *
 * Both the lazy app-open auto-close check and the migration's expired-board
 * sealing gate on this predicate, so the set of boards closed silently is
 * identical on every device.
 *
 * @param board The board to test.
 * @param nowMs Current time as epoch ms.
 * @returns `true` iff the board must auto-close.
 */
export function isBoardPastBackstop(board: SealableBoardFields, nowMs: number): boolean {
  if (!isBoardSealable(board)) return false;
  if (board.reopenedAt != null) return false;
  const deadline = computeAutoCloseDeadlineMs(board);
  if (deadline == null) return false;
  return nowMs > deadline;
}

/**
 * Whether a board is **Ended, not closed** (Board Edit redesign slice 4, D12):
 * its window is over and it is still unsealed, so it keeps accepting logs
 * (stamped at its `endDate`) until the user closes it or it auto-closes. It is
 * {@link isBoardClosingOut} restricted to non-archived boards — archived boards
 * get no Close/Reopen (OQ5). A reopened board past its end is ended again.
 *
 * @param board The board to test.
 * @param nowMs Current time as epoch ms.
 * @returns `true` iff the board shows the ENDED state.
 */
export function isBoardEnded(board: SealableBoardFields, nowMs: number): boolean {
  if (board.status === BoardStatus.ARCHIVED) return false;
  return isBoardClosingOut(board, nowMs);
}

/**
 * Whether a board is **Closed** (Board Edit redesign slice 4, D12): sealed, not
 * deleted, and ACTIVE or COMPLETED (archived boards get no Close/Reopen — OQ5).
 * A closed board is a permanent record that accepts only direct late logs and
 * can be Reopened.
 *
 * @param board The board to test.
 * @returns `true` iff the board shows the CLOSED state.
 */
export function isBoardClosed(
  board: Pick<SealableBoardFields, 'isDeleted' | 'status' | 'sealedAt'>,
): boolean {
  if (board.isDeleted) return false;
  if (board.sealedAt == null) return false;
  return board.status === BoardStatus.ACTIVE || board.status === BoardStatus.COMPLETED;
}
