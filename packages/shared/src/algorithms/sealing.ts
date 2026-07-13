import type { Board } from '../types/board';
import { isBoardIndefinite } from '../types/board';
import { BoardStatus } from '../constants/enums';
import { computeBackstopDeadlineMs } from './taskEvents';

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
  'isDeleted' | 'status' | 'timeframe' | 'startDate' | 'endDate' | 'sealedAt' | 'activatedAt'
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

/**
 * Whether a board is past its auto-seal backstop deadline (docs §Lifecycle →
 * Backstop). Sealable AND `now` is beyond the timeframe-scaled deadline, which
 * keys off `max(endDate, activatedAt)` — so a DRAFT activated after its window
 * already expired still gets one full prompt cycle before any silent seal.
 *
 * Both the lazy app-open backstop check and the migration's expired-board
 * sealing gate on this predicate, so the set of boards sealed silently is
 * identical on every device.
 *
 * @param board The board to test.
 * @param nowMs Current time as epoch ms.
 * @returns `true` iff the board must auto-seal.
 */
export function isBoardPastBackstop(board: SealableBoardFields, nowMs: number): boolean {
  if (!isBoardSealable(board)) return false;
  const deadline = computeBackstopDeadlineMs(board.startDate, board.endDate, board.activatedAt);
  if (deadline == null) return false;
  return nowMs > deadline;
}
