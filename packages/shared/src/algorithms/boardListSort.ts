import type { Board } from '../types/board';
import { BoardStatus, Timeframe } from '../constants/enums';
import { isTimeframeExpired } from './calendarBoundaries';

/**
 * Board-list ordering for the Boards screen, shared by web (`useBoards`) and
 * iOS (mirrored in `TimeframeFormatting.swift`'s `compareBoardsForList`).
 *
 * The rule (one comparator, no per-tab special-casing):
 *   1. Active boards come before non-active boards.
 *   2. Within the active group: soonest `endDate` first (ascending); boards
 *      with no deadline — INDEFINITE, or simply missing `endDate` — sort last
 *      within the group; ties break by most recent activity (`updatedAt` desc).
 *   3. Within the non-active group: most recent activity / completion first
 *      (`updatedAt` desc).
 *
 * Applied to whichever filtered set the Boards screen is showing, this yields:
 *   - the **Active** tab → all active → deadline-soonest-first;
 *   - the **Completed** / **Draft** tabs → all non-active → recency-first;
 *   - the **All** tab → active boards (by deadline) above non-active (by recency).
 *
 * "Active for sorting" means a board still in play: status ACTIVE, not sealed,
 * and not past its `endDate` — the same "still running" notion the list-filter
 * chips use (`boardMatchesListFilter`). A sealed or expired ACTIVE board sorts
 * with the non-active group.
 *
 * @param a - First board.
 * @param b - Second board.
 * @param now - Reference time for the expiry check (injectable for tests).
 * @returns Negative if `a` sorts before `b`, positive if after, 0 if equal.
 */
export function compareBoardsForList(a: Board, b: Board, now: Date = new Date()): number {
  const aActive = isActiveForSort(a, now);
  const bActive = isActiveForSort(b, now);

  // 1. Active group before non-active group.
  if (aActive !== bActive) return aActive ? -1 : 1;

  // 2. Both active — soonest deadline first, no-deadline boards last.
  if (aActive) {
    const aEnd = deadlineTime(a);
    const bEnd = deadlineTime(b);
    if (aEnd !== bEnd) {
      if (aEnd === null) return 1; // a has no deadline → after b
      if (bEnd === null) return -1; // b has no deadline → after a
      return aEnd - bEnd; // ascending: soonest first
    }
    // Same (or both-missing) deadline → most recent activity first.
    return activityDesc(a, b);
  }

  // 3. Both non-active — most recent activity / completion first.
  return activityDesc(a, b);
}

/**
 * A board "still in play": ACTIVE status, not sealed, not past its endDate —
 * the same "active" notion the Boards-tab list-filter and the comparator use.
 * Exported so the Home screen's "active boards" sections stay in lock-step with
 * the Boards tab instead of re-deriving their own (which drifted: a raw
 * `status === ACTIVE` filter wrongly kept expired/sealed boards).
 */
export function isBoardActiveForList(board: Board, now: Date = new Date()): boolean {
  return isActiveForSort(board, now);
}

/**
 * Task id → the number of DISTINCT boards it is placed on that are still in
 * play ({@link isBoardActiveForList}): the "On N other boards" usage hint on
 * the wizard's and pool editor's rows. Deleted, draft, completed, closed and
 * ended boards don't count; a placement on a board missing from `boards`
 * doesn't either. iOS twin: `activeBoardPlacementCounts` in
 * `TimeframeFormatting.swift`.
 *
 * @param boardTasks - Placements (`taskId` + `boardId`), tombstones skipped.
 * @param boards - The boards those placements may point at.
 * @param now - Reference time for the ended check.
 * @returns Counts keyed by task id; a task on no active board is absent.
 */
export function activeBoardPlacementCounts(
  boardTasks: ReadonlyArray<{ taskId: string; boardId: string; isDeleted?: boolean }>,
  boards: ReadonlyArray<Board>,
  now: Date = new Date(),
): Record<string, number> {
  const active = new Set(boards.filter((b) => !b.isDeleted && isActiveForSort(b, now)).map((b) => b.id));
  const byTask = new Map<string, Set<string>>();
  for (const bt of boardTasks) {
    if (bt.isDeleted || !active.has(bt.boardId)) continue;
    let set = byTask.get(bt.taskId);
    if (!set) byTask.set(bt.taskId, (set = new Set<string>()));
    set.add(bt.boardId);
  }
  const counts: Record<string, number> = {};
  for (const [taskId, set] of byTask) counts[taskId] = set.size;
  return counts;
}

/**
 * The status word a task's Usage list (Task Detail) shows for one of its
 * boards — the Boards tab's classification, not the stored `status`, which
 * stays ACTIVE on a board that was closed or whose window ended: `'closed'`
 * when sealed (any status), `'expired'` for an ACTIVE board past its endDate,
 * else the stored status. iOS twin: `boardPlacementStatus` in
 * `TimeframeFormatting.swift`.
 *
 * @param board - The placed-on board.
 * @param now - Reference time for the ended check.
 */
export function boardPlacementStatus(board: Board, now: Date = new Date()): BoardPlacementStatus {
  if (board.sealedAt != null) return 'closed';
  if (board.status === BoardStatus.ACTIVE && isBoardEnded(board, now)) return 'expired';
  return board.status;
}

/** A stored {@link BoardStatus}, or the two ways an ACTIVE board is over. */
export type BoardPlacementStatus = BoardStatus | 'closed' | 'expired';

/** A board "still in play": ACTIVE status, not sealed, not past its endDate. */
function isActiveForSort(board: Board, now: Date): boolean {
  if (board.status !== BoardStatus.ACTIVE) return false;
  if (board.sealedAt != null) return false;
  return !isBoardEnded(board, now);
}

/** True when a dated board is past its endDate. INDEFINITE never ends. */
function isBoardEnded(board: Board, now: Date): boolean {
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return false;
  return isTimeframeExpired(board.endDate, now);
}

/** Epoch ms of the board's deadline, or null for INDEFINITE / no endDate. */
function deadlineTime(board: Board): number | null {
  if (board.timeframe === Timeframe.INDEFINITE || !board.endDate) return null;
  const t = new Date(board.endDate).getTime();
  return Number.isFinite(t) ? t : null;
}

/** Most-recent-`updatedAt`-first comparator (descending). */
function activityDesc(a: Board, b: Board): number {
  return new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime();
}
