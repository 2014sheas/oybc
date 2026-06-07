import { db } from '../database';
import type { Board, Task, CompoundChild, CreateBoardInput } from '@oybc/shared';
import {
  BoardStatus,
  SyncOperationType,
  SyncStatus,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';

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
      // Fix #1: distinguish undefined (skip field entirely) from null (user
      // explicitly cleared the name — write undefined so IndexedDB's structured
      // clone omits the property, clearing the prior stored value).
      // The old `!= null` check swallowed null and left the prior value in place.
      if (patch.centerSquareCustomName !== undefined) {
        // null from the UI → undefined (clear); string from the UI → write it.
        sanitized.centerSquareCustomName = patch.centerSquareCustomName ?? undefined;
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

  // 3. Batch cascade: load shared tables ONCE, find the union of affected
  //    board IDs across all placed tasks, then write one stats update per
  //    affected board. This replaces the previous per-task loop which did
  //    O(N) full-table scans for a 5×5 board (25 cascade calls).
  const taskIds = Array.from(new Set(placements.map((bt) => bt.taskId)));
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();
      const allChildren = await fetchAllCompoundChildren();
      const allBoardTasks = await fetchAllBoardTasks();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        (childrenByCompound[c.compoundTaskId] ??= []).push(c);
      }

      // Collect the union of all affected board IDs across every placed task.
      const affectedBoardIds = new Set<string>();
      for (const taskId of taskIds) {
        const parents = findTransitiveParentCompounds(taskId, allChildren);
        for (const bid of findAffectedBoardIds(taskId, parents, allBoardTasks)) {
          affectedBoardIds.add(bid);
        }
      }

      // Update each affected board exactly once.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = allBoards.find((b) => b.id === affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted) continue;

        // Re-fetch so we see the just-written metadata update (updateBoard ran above).
        const freshBoard = await db.boards.get(affectedBoardId);
        if (!freshBoard || freshBoard.isDeleted) continue;

        const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === affectedBoardId);
        const stats = computeBoardStatsUpdate(
          freshBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
        );

        const isGreenlog = stats.completedTasks >= freshBoard.boardSize * freshBoard.boardSize;

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (freshBoard.version ?? 1) + 1,
        };

        if (isGreenlog && freshBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        }
        if (!isGreenlog && freshBoard.status === BoardStatus.COMPLETED) {
          boardUpdate.status = BoardStatus.ACTIVE;
          boardUpdate.completedAt = undefined;
        }

        await db.boards.update(affectedBoardId, boardUpdate);

        const updatedBoard = await db.boards.get(affectedBoardId);
        if (updatedBoard) {
          await db.syncQueue.add({
            id: generateUUID(),
            entityType: 'boards',
            entityId: affectedBoardId,
            operationType: SyncOperationType.UPDATE,
            payload: JSON.stringify(updatedBoard),
            status: SyncStatus.PENDING,
            retryCount: 0,
            createdAt: now,
            priority: 0,
          });
        }
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
 * Delete a DRAFT board and its attached BoardTask placements atomically.
 *
 * Used by the Create Hub's drafts-list delete affordance. Soft-deletes the
 * Board (so sync propagates the tombstone) and hard-deletes the BoardTask
 * rows (BoardTask has no isDeleted field — placement removal is always
 * a literal delete; see `deleteBoardTasksForBoard`). Both happen inside one
 * Dexie transaction so a mid-flight failure rolls back instead of leaving
 * orphan BoardTask rows pointing at a soft-deleted Board.
 *
 * Caller is responsible for confirming the user wants the deletion.
 */
export async function deleteDraftWithCascade(id: string): Promise<void> {
  await db.transaction('rw', [db.boards, db.boardTasks, db.syncQueue], async () => {
    const existing = await db.boards.get(id);
    if (!existing) return;
    // Helper is draft-only by design — the caller (Create Hub drafts list)
    // never passes a non-draft board. Throwing on misuse keeps the
    // helper from silently destroying ACTIVE/COMPLETED placements if a
    // future caller forgets the gate. For "delete an active board",
    // use `deleteBoard(id)` (which leaves BoardTask rows in place).
    if (existing.status !== BoardStatus.DRAFT) {
      throw new Error(
        `deleteDraftWithCascade: board ${id} has status "${existing.status}", not "draft". ` +
          `Use deleteBoard() for non-draft boards.`,
      );
    }

    const placements = await db.boardTasks.where('boardId').equals(id).toArray();
    for (const bt of placements) {
      await db.boardTasks.delete(bt.id);
      await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, bt);
    }

    const now = currentTimestamp();
    await db.boards.update(id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (existing.version ?? 0) + 1,
    });
    const board = await db.boards.get(id);
    if (board) await addToSyncQueue('boards', id, SyncOperationType.DELETE, board);
  });
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
