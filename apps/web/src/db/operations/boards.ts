import { db } from '../database';
import type { Board, CreateBoardInput } from '@oybc/shared';
import { BoardStatus, SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTask } from './orchestration';

/**
 * Board CRUD Operations
 */

// ─── Edit-active patch type ───────────────────────────────────────────────────

/**
 * Editable fields for an ACTIVE board (M2 — live-edit board metadata).
 *
 * Immutable on active boards:
 *   - `boardSize` — render as read-only chip in the UI (too disruptive to change).
 *   - `isCore`, `spawnedFromTemplateId`, `isRandomized` — internal state.
 *   - Placement set (`BoardTask` rows) — M3/M4.
 */
export interface UpdateActiveBoardPatch {
  name?: string;
  centerSquareType?: Board['centerSquareType'];
  /**
   * Cleared automatically by the write helper when `centerSquareType`
   * switches away from `CUSTOM_FREE`. Callers may still pass the old
   * value; the helper discards it.
   */
  centerSquareCustomName?: string | null;
  /**
   * Cleared automatically when `centerSquareType` switches away from
   * `CHOSEN`. Callers may still pass the old value; the helper discards
   * it.
   *
   * NOTE (center-switch asymmetry): switching CHOSEN → FREE/CUSTOM_FREE
   * does NOT hard-delete the underlying BoardTask — it preserves the
   * placement so a later switch back to CHOSEN can reuse it. The cell
   * renders as FREE/CUSTOM_FREE on top of the placement. This is
   * intentional; do not treat it as a bug.
   */
  centerTaskId?: string | null;
  timeframe?: Board['timeframe'];
  /** Local-ISO8601 (via `toLocalISO`) snap to 00:00:00.000 start-of-day. */
  startDate?: string | null;
  /** Local-ISO8601 (via `toLocalISO`) snap to 23:59:59.999 end-of-day. */
  endDate?: string | null;
}

// ─── updateBoardAndCascade ────────────────────────────────────────────────────

/**
 * Apply a metadata patch to an ACTIVE board and re-derive stats for every
 * placed task.
 *
 * Sequence:
 *   1. Apply the patch via `updateBoard` (bumps version + enqueues sync).
 *   2. Sanitize center-square fields (clear `centerTaskId` when
 *      `centerSquareType` is not CHOSEN; clear `centerSquareCustomName`
 *      when not CUSTOM_FREE).
 *   3. Fetch every `BoardTask` that places a task on this board.
 *   4. Run `runBoardCascadeForTask` for each placed task inside a single
 *      Dexie transaction covering the required tables.
 *
 * Per-task cascade (not per-board) is deliberate: timeframe/dates changes
 * can flip expiry state on placed tasks, and each task's derivation reads
 * from board.timeframe + board.endDate — so every placed task needs a
 * re-derive.
 *
 * NOTE on renaming: board lookups are by id, so renaming propagates
 * everywhere (Achievement tasks watching this board, recurring-template
 * spawn metadata, etc.) without any extra work. Renaming a board does NOT
 * propagate to its spawning template name or to historical spawns —
 * references are always by id.
 *
 * @param boardId - Board to update.
 * @param patch - Editable fields for ACTIVE boards.
 */
export async function updateBoardAndCascade(
  boardId: string,
  patch: UpdateActiveBoardPatch,
): Promise<void> {
  // Build the sanitized Partial<Board> for updateBoard.
  // Board.startDate / endDate / centerSquareCustomName / centerTaskId are
  // typed as `string` (non-nullable) on the Board model, but an edit may
  // want to clear centerSquareCustomName or centerTaskId. We represent
  // "clear" as `undefined` in the Partial update (Dexie skips undefined keys).
  // For startDate/endDate the EditBoardSheet always provides a concrete
  // string, so null is converted to undefined as a safety net.
  const { CenterSquareType } = await import('@oybc/shared');

  const sanitized: Partial<Board> = {};
  if (patch.name !== undefined) sanitized.name = patch.name;
  if (patch.timeframe !== undefined) sanitized.timeframe = patch.timeframe;
  if (patch.startDate != null) sanitized.startDate = patch.startDate;
  if (patch.endDate != null) sanitized.endDate = patch.endDate;

  if (patch.centerSquareType !== undefined) {
    sanitized.centerSquareType = patch.centerSquareType;
    // Sanitize auxiliary center fields based on the new type.
    if (patch.centerSquareType === CenterSquareType.CUSTOM_FREE) {
      if (patch.centerSquareCustomName != null) {
        sanitized.centerSquareCustomName = patch.centerSquareCustomName;
      }
    } else {
      // Switching away from CUSTOM_FREE → clear the custom name.
      sanitized.centerSquareCustomName = undefined;
    }
    if (patch.centerSquareType !== CenterSquareType.CHOSEN) {
      // Switching away from CHOSEN → clear centerTaskId so no stale
      // reference remains. The underlying BoardTask row is preserved
      // (the placement lives in boardTasks, not on the board row itself).
      // NOTE (center-switch asymmetry): switching CHOSEN → FREE/CUSTOM_FREE
      // does NOT delete the BoardTask row — the placement is retained so a
      // later switch back to CHOSEN can reuse it. The board.centerTaskId
      // field merely controls which type the center cell renders as.
      sanitized.centerTaskId = undefined;
    } else if (patch.centerTaskId != null) {
      sanitized.centerTaskId = patch.centerTaskId;
    }
  }

  // 1. Apply patch (bumps version, enqueues boards sync entry).
  await updateBoard(boardId, sanitized);

  // 2. Fetch placed tasks.
  const placements = await db.boardTasks
    .where('boardId')
    .equals(boardId)
    .toArray();

  if (placements.length === 0) return;

  // 3. Re-derive every placed task inside one transaction. One
  //    `runBoardCascadeForTask` call resolves the full affected-board set,
  //    so multiple calls for tasks on the same board are safe (idempotent
  //    stat writes) — they all see the freshly-written board row.
  const taskIds = Array.from(new Set(placements.map((bt) => bt.taskId)));
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      for (const taskId of taskIds) {
        await runBoardCascadeForTask(taskId);
      }
    },
  );
}

/**
 * Fetch all boards for a user (excluding deleted)
 */
export async function fetchBoards(userId: string): Promise<Board[]> {
  return db.boards
    .filter((b) => b.userId === userId && !b.isDeleted)
    .reverse()
    .sortBy('updatedAt');
}

/**
 * Fetch a single board by ID
 */
export async function fetchBoard(id: string): Promise<Board | undefined> {
  return db.boards.get(id);
}

/**
 * Create a new board
 */
export async function createBoard(
  userId: string,
  input: CreateBoardInput,
  /** Optional fields not on CreateBoardInput. Currently used by the
   *  wizard to carry the Phase 6.1 `isCore` marker when launched from
   *  the recurring banner. Kept off CreateBoardInput so external
   *  callers don't need to think about provenance fields. */
  options: { isCore?: boolean } = {},
): Promise<Board> {
  const board: Board = {
    id: generateUUID(),
    userId,
    name: input.name,
    description: input.description,
    status: BoardStatus.DRAFT,
    boardSize: input.boardSize,
    timeframe: input.timeframe,
    startDate: input.startDate,
    endDate: input.endDate,
    centerSquareType: input.centerSquareType,
    centerSquareCustomName: input.centerSquareCustomName,
    centerTaskId: input.centerTaskId,
    isRandomized: input.isRandomized,
    totalTasks: input.boardSize * input.boardSize,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
    isCore: options.isCore === true,
  };

  await db.boards.add(board);
  await addToSyncQueue('boards', board.id, SyncOperationType.CREATE, board);
  return board;
}

/**
 * Update a board
 */
export async function updateBoard(
  id: string,
  updates: Partial<Board>
): Promise<void> {
  const board = await db.boards.get(id);
  if (!board) return;
  await db.boards.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  const updated = await db.boards.get(id);
  if (updated) await addToSyncQueue('boards', id, SyncOperationType.UPDATE, updated);
}

/**
 * Soft delete a board.
 *
 * Increments `version` so LWW conflict resolution treats the deletion
 * as a later-wins operation against any concurrent update on another
 * device. See `deleteTask` for the same rationale.
 */
export async function deleteBoard(id: string): Promise<void> {
  const existing = await db.boards.get(id);
  if (!existing) return;
  await db.boards.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const board = await db.boards.get(id);
  if (board) await addToSyncQueue('boards', id, SyncOperationType.DELETE, board);
}

/**
 * Update board stats (denormalized)
 */
export async function updateBoardStats(
  boardId: string,
  stats: {
    completedTasks?: number;
    linesCompleted?: number;
    completedLineIds?: string[];
  }
): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board) return;
  await db.boards.update(boardId, {
    ...stats,
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  const updatedBoard = await db.boards.get(boardId);
  if (updatedBoard) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, updatedBoard);
}

/**
 * Mark board as completed
 */
export async function completeBoard(boardId: string): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board) return;
  await db.boards.update(boardId, {
    status: BoardStatus.COMPLETED,
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  const completedBoard = await db.boards.get(boardId);
  if (completedBoard) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, completedBoard);
}

/**
 * Activate a board (transition from DRAFT to ACTIVE)
 *
 * @param boardId - The board to activate
 */
export async function activateBoard(boardId: string): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board || board.status !== BoardStatus.DRAFT) return;
  await db.boards.update(boardId, {
    status: BoardStatus.ACTIVE,
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  // Re-fetch so the enqueued payload captures the post-activate status
  // and bumped version — otherwise Firestore would only ever see the
  // original DRAFT snapshot from the paired create, and the ACTIVE
  // transition wouldn't reach other devices until an unrelated update.
  const activated = await db.boards.get(boardId);
  if (activated) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, activated);
}

/**
 * Fetch boards by timeframe (for achievement tracking)
 */
export async function fetchBoardsByTimeframe(
  userId: string,
  timeframe: string
): Promise<Board[]> {
  return db.boards
    .where('[userId+timeframe+status]')
    // Dexie's `.equals()` signature takes `IndexableType` and doesn't
    // model compound-index tuples; `any` is the project convention for
    // this specific library-typing quirk.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    .equals([userId, timeframe, BoardStatus.COMPLETED] as any)
    .toArray();
}

/**
 * Count boards with bingos by timeframe
 */
export async function countBingos(
  userId: string,
  timeframe: string
): Promise<number> {
  return db.boards
    .where('[userId+timeframe+linesCompleted]')
    .between(
      [userId, timeframe, 1] as readonly unknown[],
      [userId, timeframe, Infinity] as readonly unknown[]
    )
    .count();
}

/**
 * Count completed boards by timeframe
 */
export async function countCompletedBoards(
  userId: string,
  timeframe: string
): Promise<number> {
  return db.boards
    .filter((b) => b.userId === userId && !b.isDeleted && b.timeframe === timeframe && b.status === 'completed')
    .count();
}
