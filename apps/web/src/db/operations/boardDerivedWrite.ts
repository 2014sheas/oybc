import {
  BoardStatus,
  SyncOperationType,
  boardDerivedStateChanged,
  type Board,
  type BoardStatsUpdate,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';

/** Outcome of {@link writeBoardDerivedStats}. */
export interface BoardDerivedWriteResult {
  /** True when the row was written (something derived actually changed). */
  written: boolean;
  /** The write flipped the board ACTIVE → COMPLETED (greenlog). */
  boardCompleted: boolean;
  /** The write flipped the board COMPLETED → ACTIVE. */
  boardReactivated: boolean;
}

/**
 * Persist one board's freshly derived stats + the greenlog status transition —
 * the shared tail of every live board cascade (task-driven, board-driven, the
 * edit cascades). Compare-before-write (sync-churn fix): when
 * `boardDerivedStateChanged` says the derived fields are unchanged, nothing is
 * written, `version` / `updatedAt` stay put and nothing is enqueued, so a
 * cascade re-run on converged data (an own-push echo, a no-op edit, an empty
 * draft) can no longer bump and re-push the board.
 *
 * `authored` (default `true`) bumps `version` + `updatedAt` and enqueues the
 * Board UPDATE; `authored: false` writes the same fields in place (the
 * pull-path refresh contract — see `CascadeOptions` in orchestration.ts).
 *
 * Must run inside the caller's Dexie `rw` transaction covering `boards` and
 * `syncQueue`.
 *
 * @param board The stored board row the stats were derived from.
 * @param stats The derivation output for that board.
 * @param now   The write timestamp (also the `completedAt` of a greenlog flip).
 * @param opts  `authored` — see above.
 * @returns Whether a write happened and which status transition it made.
 */
export async function writeBoardDerivedStats(
  board: Board,
  stats: BoardStatsUpdate,
  now: string,
  opts: { authored?: boolean } = {},
): Promise<BoardDerivedWriteResult> {
  const authored = opts.authored ?? true;
  const isGreenlog = stats.completedTasks >= board.boardSize * board.boardSize;

  // Typed as `Partial<Board>` so Dexie 4's `UpdateSpec<T>` accepts it.
  const derived: Partial<Board> = {
    completedTasks: stats.completedTasks,
    linesCompleted: stats.linesCompleted,
    completedLineIds: stats.completedLineIds,
  };
  let boardCompleted = false;
  let boardReactivated = false;
  if (isGreenlog && board.status === BoardStatus.ACTIVE) {
    derived.status = BoardStatus.COMPLETED;
    derived.completedAt = now;
    boardCompleted = true;
  } else if (!isGreenlog && board.status === BoardStatus.COMPLETED) {
    derived.status = BoardStatus.ACTIVE;
    derived.completedAt = undefined;
    boardReactivated = true;
  }

  if (!boardDerivedStateChanged(board, { ...board, ...derived })) {
    return { written: false, boardCompleted: false, boardReactivated: false };
  }

  const update: Partial<Board> = authored
    ? { ...derived, updatedAt: now, version: (board.version ?? 1) + 1 }
    : derived;
  await db.boards.update(board.id, update);

  if (authored) {
    const updated = await db.boards.get(board.id);
    if (updated) await addToSyncQueue('boards', board.id, SyncOperationType.UPDATE, updated, 0);
  }
  return { written: true, boardCompleted, boardReactivated };
}
