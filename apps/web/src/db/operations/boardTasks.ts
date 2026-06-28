import { db } from '../database';
import type { BoardTask, CreateBoardTaskInput } from '@oybc/shared';
import {
  SyncOperationType,
  SyncStatus,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  BoardStatus,
  type Board,
  type Task,
  type CompoundChild,
  type BoardStatsUpdate,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';

/**
 * BoardTask CRUD Operations
 */

/**
 * Fetch all board tasks for a board
 */
export async function fetchBoardTasks(boardId: string): Promise<BoardTask[]> {
  return db.boardTasks.where('boardId').equals(boardId).toArray();
}

/**
 * Fetch a single board task by ID
 */
export async function fetchBoardTask(id: string): Promise<BoardTask | undefined> {
  return db.boardTasks.get(id);
}

/**
 * Hard-deletes every `BoardTask` row for the given board and queues
 * each removal for sync. Used when re-saving a draft whose task
 * placement has changed — simpler than diffing the old layout
 * against the new one, and tolerable at scale (at most 25 cells).
 *
 * `BoardTask` has no `isDeleted` flag, so the deletion is literal;
 * the sync queue `DELETE` operation propagates removal to Firestore
 * and other devices apply the delete on their next pull.
 */
export async function deleteBoardTasksForBoard(boardId: string): Promise<void> {
  const tasks = await db.boardTasks.where('boardId').equals(boardId).toArray();
  for (const bt of tasks) {
    await db.boardTasks.delete(bt.id);
    await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, bt);
  }
}

/**
 * Fetch every BoardTask in the workspace.
 *
 * Used by the derivation pass to find which boards are affected by a
 * Task state change. Small-N: every BoardTask across every board.
 * Typical user has fewer than a few thousand.
 *
 * Note: BoardTask has no isDeleted field (placement removals are hard
 * deletes), so all returned rows are live.
 */
export async function fetchAllBoardTasks(): Promise<BoardTask[]> {
  return db.boardTasks.toArray();
}

/**
 * Fetch BoardTask rows for the given board ids, grouped by boardId.
 * Returns a Map keyed by boardId; boards with no BoardTasks have an empty array entry.
 */
export async function fetchBoardTasksForBoards(
  boardIds: string[],
): Promise<Map<string, BoardTask[]>> {
  const out = new Map<string, BoardTask[]>();
  for (const id of boardIds) out.set(id, []);
  if (boardIds.length === 0) return out;
  const rows = await db.boardTasks.where('boardId').anyOf(boardIds).toArray();
  for (const row of rows) {
    const arr = out.get(row.boardId);
    if (arr) arr.push(row);
  }
  return out;
}

/**
 * Create a board task (add task to board).
 *
 * Phase 6.3 — BoardTask is a pure placement record. Achievement-square
 * configuration moved to `Task` (`type === ACHIEVEMENT` + reference
 * fields); see `apps/web/src/db/operations/tasks.ts` for the achievement
 * task creation path. Cycle detection for ACHIEVEMENT tasks happens at
 * the UI layer before this helper runs.
 */
export async function createBoardTask(
  input: CreateBoardTaskInput
): Promise<BoardTask> {
  const boardTask: BoardTask = {
    id: generateUUID(),
    boardId: input.boardId,
    taskId: input.taskId,
    row: input.row,
    col: input.col,
    isCenter: input.isCenter,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
  };

  await db.boardTasks.add(boardTask);
  await addToSyncQueue('boardTasks', boardTask.id, SyncOperationType.CREATE, boardTask);
  return boardTask;
}

/**
 * Find all boards using a specific task
 */
export async function fetchBoardsUsingTask(taskId: string): Promise<string[]> {
  const boardTasks = await db.boardTasks.where('taskId').equals(taskId).toArray();
  return [...new Set(boardTasks.map((bt) => bt.boardId))];
}

// ─── removeBoardTaskFromBoard ────────────────────────────────────────────────

/**
 * Remove a single BoardTask placement from an ACTIVE board (live-edit M4).
 *
 * Semantics:
 *   - Hard-deletes the BoardTask row (BoardTask has no isDeleted field; removal
 *     is always a physical delete, consistent with `deleteBoardTasksForBoard`).
 *   - Enqueues a DELETE sync entry so the tombstone propagates to Firestore.
 *   - Runs the batched cascade pattern from M2/M3: computes affected board IDs
 *     for the removed task (and any compound parents), then re-derives board stats
 *     + status for every affected board in one Dexie transaction.
 *
 * The underlying Task is NOT touched — it stays in the library and on other boards.
 * Only this board loses the placement.
 *
 * Caller is responsible for:
 *   - Confirming the board is ACTIVE (not expired) before calling.
 *   - Ensuring the target BoardTask is not the center square.
 *
 * @param boardTaskId - The `BoardTask.id` placement record to remove.
 */
export async function removeBoardTaskFromBoard(boardTaskId: string): Promise<void> {
  const existing = await db.boardTasks.get(boardTaskId);
  if (!existing) return;

  const now = currentTimestamp();
  const removedTaskId = existing.taskId;

  // Gather workspace data BEFORE the delete so we can compute affected boards.
  const allBoardTasksPre = await db.boardTasks.toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Affected boards: those placing the removed task directly OR via a compound parent.
  const parents = findTransitiveParentCompounds(removedTaskId, allCompoundChildren);
  const affectedBoardIds = Array.from(findAffectedBoardIds(removedTaskId, parents, allBoardTasksPre));

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // 1. Hard-delete the BoardTask placement.
      await db.boardTasks.delete(boardTaskId);

      // Enqueue DELETE tombstone for sync.
      await db.syncQueue.add({
        id: generateUUID(),
        entityType: 'boardTasks',
        entityId: boardTaskId,
        operationType: SyncOperationType.DELETE,
        payload: JSON.stringify(existing),
        status: SyncStatus.PENDING,
        retryCount: 0,
        createdAt: now,
        priority: 0,
      });

      // 2. Fetch post-delete state for cascade pass.
      const allBoardTasksPost = await db.boardTasks.toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted) continue;

        const boardTasksOnBoard = allBoardTasksPost.filter(
          (bt) => bt.boardId === affectedBoardId,
        );

        const stats: BoardStatsUpdate = computeBoardStatsUpdate(
          affectedBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
        );

        const totalSquares = affectedBoard.boardSize * affectedBoard.boardSize;
        const isGreenlog = stats.completedTasks >= totalSquares;

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
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

// ─── addBoardTaskToBoard ──────────────────────────────────────────────────────

/**
 * Add a Task to an empty cell on an ACTIVE board (live-edit M4).
 *
 * Creates a new BoardTask placement record at the given grid position and runs
 * the batched cascade pattern (same approach as M2/M3) to re-derive stats for
 * every board affected by the newly-placed task.
 *
 * Shared-task semantics: if the task is already globally completed (isCompleted
 * is true on the Task row), the cascade immediately counts this cell as
 * completed and increments board.completedTasks. No cloning, no reset.
 *
 * Caller is responsible for:
 *   - Confirming the target cell is currently empty.
 *   - Confirming the board is ACTIVE (not expired) before calling.
 *   - Confirming the cell is not the center square.
 *   - Confirming the task is not already placed at this exact cell on this board.
 *
 * @param boardId - The board receiving the new placement.
 * @param taskId - The task to place.
 * @param row - Grid row (0-based).
 * @param col - Grid column (0-based).
 * @returns The newly-created BoardTask record.
 */
export async function addBoardTaskToBoard(
  boardId: string,
  taskId: string,
  row: number,
  col: number,
): Promise<BoardTask> {
  const now = currentTimestamp();

  const newBoardTask: BoardTask = {
    id: generateUUID(),
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: now,
    updatedAt: now,
    version: 1,
  };

  // Gather workspace data BEFORE the insert for affected-board computation.
  const allBoardTasksPre = await db.boardTasks.toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Compute affected boards using the post-insert state (the new placement is included).
  const syntheticBoardTasks: BoardTask[] = [...allBoardTasksPre, newBoardTask];
  const parents = findTransitiveParentCompounds(taskId, allCompoundChildren);
  const affectedBoardIds = Array.from(findAffectedBoardIds(taskId, parents, syntheticBoardTasks));

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // 1. Write the new BoardTask placement.
      await db.boardTasks.add(newBoardTask);
      await db.syncQueue.add({
        id: generateUUID(),
        entityType: 'boardTasks',
        entityId: newBoardTask.id,
        operationType: SyncOperationType.CREATE,
        payload: JSON.stringify(newBoardTask),
        status: SyncStatus.PENDING,
        retryCount: 0,
        createdAt: now,
        priority: 0,
      });

      // 2. Fetch post-insert state for cascade pass.
      const allBoardTasksPost = await db.boardTasks.toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted) continue;

        const boardTasksOnBoard = allBoardTasksPost.filter(
          (bt) => bt.boardId === affectedBoardId,
        );

        const stats: BoardStatsUpdate = computeBoardStatsUpdate(
          affectedBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
        );

        const totalSquares = affectedBoard.boardSize * affectedBoard.boardSize;
        const isGreenlog = stats.completedTasks >= totalSquares;

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
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

  return newBoardTask;
}

// ─── reorderBoardTasks ───────────────────────────────────────────────────────

/**
 * Describes a single position-change for a BoardTask row.
 * Used by the Phase-3 staged-rearrange Save commit path.
 */
export interface BoardTaskMove {
  boardTaskId: string;
  row: number;
  col: number;
}

/**
 * Atomically apply position changes to one board's BoardTask rows, then
 * re-derive the board's positional bingo lines.
 *
 * Called at Save time after staged-draft Replace/Edit commits (Phase 3).
 *
 * Design invariants:
 *   - All moves are written in ONE Dexie transaction → no two rows transiently
 *     share the same (row, col) from the perspective of outside readers.
 *   - Global Task completion (isCompleted / currentCount) is NEVER touched —
 *     it rides with the task to its new slot.
 *   - Bingo lines (`completedLineIds` / `linesCompleted`) are re-derived via
 *     `computeBoardStatsUpdate` on the post-move board-task snapshot because
 *     bingos are positional (row, column, diagonal).
 *   - `completedTasks` is also re-derived (unchanged in value — task completion
 *     states are global) but kept consistent via the same cascade pass.
 *   - Each moved BoardTask row is bump-versioned and enqueued for sync UPDATE.
 *   - The board row is bump-versioned and enqueued for sync UPDATE.
 *
 * @param boardId - The board whose placements are being reordered.
 * @param moves - Array of `{ boardTaskId, row, col }` describing each moved row.
 *                Must not include center-square rows (the caller — BoardPlaySurface —
 *                filters them out since the center is pinned). Must not be empty.
 */
export async function reorderBoardTasks(
  boardId: string,
  moves: BoardTaskMove[],
): Promise<void> {
  if (moves.length === 0) return;

  const now = currentTimestamp();

  // Gather workspace data once before the transaction (cheap snapshot reads).
  const allTasks = await db.tasks.toArray();
  const allBoards = await db.boards.toArray();
  const allChildren = await db.compoundChildren.toArray();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    if (!c.isDeleted) {
      (childrenByCompound[c.compoundTaskId] ??= []).push(c);
    }
  }

  const board = allBoards.find((b) => b.id === boardId);
  if (!board || board.isDeleted) return;

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.syncQueue],
    async () => {
      // 1. Write new row/col for every moved BoardTask (version-bumped; isCenter kept).
      for (const move of moves) {
        const existing = await db.boardTasks.get(move.boardTaskId);
        if (!existing) continue;

        const patched: BoardTask = {
          ...existing,
          row: move.row,
          col: move.col,
          // isCenter is intentionally preserved — rearrange never converts center squares.
          updatedAt: now,
          version: (existing.version ?? 0) + 1,
        };
        await db.boardTasks.put(patched);
        await db.syncQueue.add({
          id: generateUUID(),
          entityType: 'boardTasks',
          entityId: move.boardTaskId,
          operationType: SyncOperationType.UPDATE,
          payload: JSON.stringify(patched),
          status: SyncStatus.PENDING,
          retryCount: 0,
          createdAt: now,
          priority: 0,
        });
      }

      // 2. Re-derive bingo lines for this board from the post-move snapshot.
      //    Bingo lines are positional (row / col / diagonal), so any position
      //    change can create or break lines. Global Task completion is unchanged.
      const boardTasksOnBoard = await db.boardTasks
        .where('boardId')
        .equals(boardId)
        .toArray();

      const stats: BoardStatsUpdate = computeBoardStatsUpdate(
        board,
        boardTasksOnBoard,
        childrenByCompound,
        taskById,
        allBoards,
      );

      const totalSquares = board.boardSize * board.boardSize;
      const isGreenlog = stats.completedTasks >= totalSquares;

      const boardUpdate: Partial<Board> = {
        completedTasks: stats.completedTasks,
        linesCompleted: stats.linesCompleted,
        completedLineIds: stats.completedLineIds,
        updatedAt: now,
        version: (board.version ?? 1) + 1,
      };

      if (isGreenlog && board.status === BoardStatus.ACTIVE) {
        boardUpdate.status = BoardStatus.COMPLETED;
        boardUpdate.completedAt = now;
      } else if (!isGreenlog && board.status === BoardStatus.COMPLETED) {
        boardUpdate.status = BoardStatus.ACTIVE;
        boardUpdate.completedAt = undefined;
      }

      await db.boards.update(boardId, boardUpdate);

      const updatedBoard = await db.boards.get(boardId);
      if (updatedBoard) {
        await db.syncQueue.add({
          id: generateUUID(),
          entityType: 'boards',
          entityId: boardId,
          operationType: SyncOperationType.UPDATE,
          payload: JSON.stringify(updatedBoard),
          status: SyncStatus.PENDING,
          retryCount: 0,
          createdAt: now,
          priority: 0,
        });
      }
    },
  );
}

// ─── updateBoardTaskAndCascade ────────────────────────────────────────────────

/**
 * Patch a BoardTask's `taskId` (cell swap) and run the board derivation
 * cascade for every board affected by either the OLD task or the NEW task.
 *
 * Design mirrors `updateTaskAndCascade` (M1) and the batched cascade from
 * `updateBoardAndCascade` (M2/PR #95):
 *   1. Apply the taskId patch atomically (bumps version + enqueues boardTask sync).
 *   2. Build the union of affected board IDs across both the old and new task:
 *      - Boards where the OLD task was placed (they need to re-derive because
 *        the task is no longer there).
 *      - Boards where the NEW task is placed (they need to re-derive because
 *        the task is now there, potentially forming new bingos).
 *   3. Run one derivation pass per affected board inside a single transaction.
 *
 * Counter-overshoot invariant: derivation never clamps `currentCount`. The cascade
 * delegates to `computeBoardStatsUpdate`, which reads `task.isCompleted` for non-
 * counting tasks; for counting tasks the actual over-max value is preserved on the
 * Task row and the cascade only recalculates board-level stats (bingos, completedTasks).
 *
 * Caller is responsible for:
 *   - Confirming the board is ACTIVE (not expired/archived) before calling.
 *   - Ensuring the target `BoardTask` cell (identified by `boardTaskId`) is not the center square.
 *   - Providing a `newTaskId` that is NOT the same as the current `taskId` (no-op
 *     guard: if they are equal, the function returns immediately without writing).
 *
 * @param boardTaskId - The `BoardTask.id` placement record to update.
 * @param newTaskId - The new `Task.id` to write into `BoardTask.taskId`.
 */
export async function updateBoardTaskAndCascade(
  boardTaskId: string,
  newTaskId: string,
): Promise<void> {
  // 1. Fetch the existing BoardTask.
  const existing = await db.boardTasks.get(boardTaskId);
  if (!existing) return;

  const oldTaskId = existing.taskId;
  // No-op guard: swapping to the same task is a no-op.
  if (oldTaskId === newTaskId) return;

  const now = currentTimestamp();

  // 2. Gather all workspace data for the cascade pass (fetched once outside
  //    the transaction so the transaction body stays thin).
  const allBoardTasksPre = await db.boardTasks.toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Build the union of affected board IDs for OLD and NEW tasks.
  // We use the pre-patch boardTask list for the old-task side (the old task
  // still occupies this cell), and synthesise the new state for the new task
  // side (after the patch the new task will be at this cell).
  // The simplest correct approach: compute affected boards for old task using
  // current state (which still has oldTaskId at this cell), then compute
  // affected boards for new task using a synthetic list where the cell carries
  // newTaskId.
  const syntheticBoardTasks: BoardTask[] = allBoardTasksPre.map((bt) =>
    bt.id === boardTaskId ? { ...bt, taskId: newTaskId } : bt,
  );

  const oldParents = findTransitiveParentCompounds(oldTaskId, allCompoundChildren);
  const oldAffected = findAffectedBoardIds(oldTaskId, oldParents, allBoardTasksPre);

  const newParents = findTransitiveParentCompounds(newTaskId, allCompoundChildren);
  const newAffected = findAffectedBoardIds(newTaskId, newParents, syntheticBoardTasks);

  const affectedBoardIds = Array.from(new Set([...oldAffected, ...newAffected]));

  // 3. Write the patch + cascade in one transaction.
  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // 3a. Patch the BoardTask row.
      const patched: BoardTask = {
        ...existing,
        taskId: newTaskId,
        updatedAt: now,
        version: (existing.version ?? 0) + 1,
      };
      await db.boardTasks.put(patched);
      await db.syncQueue.add({
        id: generateUUID(),
        entityType: 'boardTasks',
        entityId: boardTaskId,
        operationType: SyncOperationType.UPDATE,
        payload: JSON.stringify(patched),
        status: SyncStatus.PENDING,
        retryCount: 0,
        createdAt: now,
        priority: 0,
      });

      // 3b. Fetch fresh workspace data inside the transaction for the cascade pass.
      //     We need the post-patch boardTask list and the full task / child sets.
      const allBoardTasksPost = await db.boardTasks.toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3c. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted) continue;

        const boardTasksOnBoard = allBoardTasksPost.filter(
          (bt) => bt.boardId === affectedBoardId,
        );

        const stats: BoardStatsUpdate = computeBoardStatsUpdate(
          affectedBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
        );

        const totalSquares = affectedBoard.boardSize * affectedBoard.boardSize;
        const isGreenlog = stats.completedTasks >= totalSquares;

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
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
