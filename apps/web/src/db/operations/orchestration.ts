import { db } from '../database';
import {
  BoardStatus,
  TaskType,
  SyncOperationType,
  SyncStatus,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  type Task,
  type CompoundChild,
  type BoardStatsUpdate,
} from '@oybc/shared';
import { currentTimestamp, generateUUID } from '../utils';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Result of a task completion, including bingo detection and board status changes.
 *
 * @property newBingos - Line IDs that became complete (not previously in board.completedLineIds)
 * @property lostBingos - Line IDs that became incomplete (were in board.completedLineIds, now gone)
 * @property isGreenlog - True when every square on the board is complete (primary board)
 * @property boardCompleted - True if the primary board status transitioned to COMPLETED
 * @property boardReactivated - True if the primary board reverted from COMPLETED to ACTIVE
 * @property collateralBingosByBoard - New bingo lines on OTHER boards that completed as a result
 *   of this write cascading through shared Tasks. Keyed by boardId; empty when no cascade occurred.
 */
export interface TaskCompletionResult {
  newBingos: string[];
  lostBingos: string[];
  isGreenlog: boolean;
  boardCompleted: boolean;
  boardReactivated: boolean;
  collateralBingosByBoard: Record<string, string[]>;
}

/** Extended board stats including transition signals from a cascade pass. */
export interface BoardCascadeEntry extends BoardStatsUpdate {
  boardCompleted: boolean;
  boardReactivated: boolean;
}

// ─── Shared cascade helper ────────────────────────────────────────────────────

/**
 * Run the derivation pass for a Task that just changed (locally OR via pull).
 *
 * Recomputes board stats + status transitions + sync entries for every board
 * affected by `changedTaskId` directly or via a containing compound.
 *
 * Pure cascade — does NOT write the Task itself. Caller owns that write.
 *
 * Pulls do NOT bump Task version (pulled value is authoritative); calling
 * this helper from a pull handler handles the cascade without re-firing
 * the write-path Task update.
 *
 * IMPORTANT: Must be called inside an active Dexie transaction covering
 * `boards`, `boardTasks`, `tasks`, `compoundChildren`, and `syncQueue`.
 * Dexie's auto-batching joins the caller's transaction automatically when
 * invoked within `db.transaction('rw', [...], async () => { ... })`.
 *
 * @param changedTaskId The Task whose state just changed.
 * @returns A map of boardId → BoardCascadeEntry for every recomputed board,
 *   so callers can extract collateral signals (e.g., new bingos).
 */
export async function runBoardCascadeForTask(
  changedTaskId: string,
): Promise<Map<string, BoardCascadeEntry>> {
  const now = currentTimestamp();

  // Build the lookups for the derivation pass.
  const allChildren = await fetchAllCompoundChildren();
  const allBoardTasks = await fetchAllBoardTasks();
  const allTasks = await db.tasks.toArray();
  // Phase 6.3 — `computeBoardStatsUpdate` needs the workspace's boards
  // to evaluate the specific-board / recurring-template achievement
  // branches. Pre-6.3 callers passed nothing here and the algorithm
  // defaults to `[]`, but on this cascade path we have the full set
  // available, so use it.
  const allBoards = await db.boards.toArray();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }

  // Resolve affected boards via the shared derivation helpers.
  const parentCompounds = findTransitiveParentCompounds(changedTaskId, allChildren);
  const affectedBoardIds = findAffectedBoardIds(changedTaskId, parentCompounds, allBoardTasks);

  const resultMap = new Map<string, BoardCascadeEntry>();

  for (const affectedBoardId of affectedBoardIds) {
    const affectedBoard = await db.boards.get(affectedBoardId);
    if (!affectedBoard || affectedBoard.isDeleted) continue;

    const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === affectedBoardId);
    const stats: BoardStatsUpdate = computeBoardStatsUpdate(
      affectedBoard,
      boardTasksOnBoard,
      childrenByCompound,
      taskById,
      allBoards,
    );

    const totalSquares = affectedBoard.boardSize * affectedBoard.boardSize;
    const isGreenlog = stats.completedTasks >= totalSquares;

    let boardCompleted = false;
    let boardReactivated = false;

    const boardUpdate: Record<string, unknown> = {
      completedTasks: stats.completedTasks,
      linesCompleted: stats.linesCompleted,
      completedLineIds: stats.completedLineIds,
      updatedAt: now,
      version: (affectedBoard.version ?? 1) + 1,
    };

    // Auto-complete board on greenlog.
    if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
      boardUpdate.status = BoardStatus.COMPLETED;
      boardUpdate.completedAt = now;
      boardCompleted = true;
    }

    // Revert COMPLETED → ACTIVE if board is no longer fully complete.
    if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
      boardUpdate.status = BoardStatus.ACTIVE;
      boardUpdate.completedAt = undefined;
      boardReactivated = true;
    }

    await db.boards.update(affectedBoardId, boardUpdate);

    // Enqueue sync for this board (inside the transaction for all-or-nothing semantics).
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
        createdAt: currentTimestamp(),
        priority: 0,
      });
    }

    resultMap.set(affectedBoardId, {
      ...stats,
      boardCompleted,
      boardReactivated,
    });
  }

  return resultMap;
}

// ─── Orchestration ───────────────────────────────────────────────────────────

/**
 * Handles a task completion event on a board, orchestrating the full chain:
 * update the underlying global Task → run the shared derivation pass →
 * recompute stats + status for every affected board → enqueue sync.
 *
 * Because Tasks are global (not per-board), completing a Task that appears on
 * multiple boards or is a child of compound Tasks on other boards cascades
 * automatically. All writes happen inside a single Dexie transaction.
 *
 * The caller uses the return value to trigger celebrations immediately (rather
 * than waiting for reactive hook updates which may lag by a frame).
 *
 * @param boardId - The primary board the user interacted with
 * @param boardTaskId - The specific BoardTask the user tapped/checked
 * @param updates - Partial update to apply (isCompleted, currentCount).
 *   `completedStepIds` is no longer supported; pass it and this function throws.
 * @returns TaskCompletionResult with new bingos, greenlog status, board completion flag,
 *   and cascading bingos on other boards.
 */
export async function handleTaskCompletion(
  boardId: string,
  boardTaskId: string,
  updates: {
    isCompleted?: boolean;
    currentCount?: number;
    completedStepIds?: string[];
  }
): Promise<TaskCompletionResult> {
  // Reject the legacy completedStepIds param — there is no per-board step state
  // under the unified compound model. Toggle each leaf Task directly instead.
  if (updates.completedStepIds !== undefined) {
    throw new Error(
      'completedStepIds is no longer supported under the unified compound model. ' +
        'Toggle leaf Tasks directly via handleTaskCompletion(boardId, leafBoardTaskId, { isCompleted: true }).',
    );
  }

  let result: TaskCompletionResult = {
    newBingos: [],
    lostBingos: [],
    isGreenlog: false,
    boardCompleted: false,
    boardReactivated: false,
    collateralBingosByBoard: {},
  };

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch + auto-activate the primary board.
      let primaryBoard = await db.boards.get(boardId);
      if (!primaryBoard) throw new Error(`Board ${boardId} not found`);

      if (primaryBoard.status === BoardStatus.DRAFT) {
        await db.boards.update(boardId, {
          status: BoardStatus.ACTIVE,
          updatedAt: now,
          version: (primaryBoard.version ?? 1) + 1,
        });
        // Re-fetch to get updated version for subsequent writes.
        primaryBoard = (await db.boards.get(boardId))!;
      }

      // 2. Resolve target BoardTask + its underlying Task.
      const targetBt = await db.boardTasks.get(boardTaskId);
      if (!targetBt) throw new Error(`BoardTask ${boardTaskId} not found`);
      if (targetBt.boardId !== boardId) {
        throw new Error(`BoardTask ${boardTaskId} does not belong to board ${boardId}`);
      }

      const targetTask = await db.tasks.get(targetBt.taskId);
      if (!targetTask) throw new Error(`Task ${targetBt.taskId} not found`);

      // Compound squares are read-only on the grid. Their state derives from
      // children — clients toggle children, not the compound itself.
      if (targetTask.type === TaskType.COMPOUND) {
        throw new Error(
          'Compound BoardTasks are read-only on the grid. Toggle a child task ' +
            'via the detail sheet — its completion cascades to this compound automatically.',
        );
      }

      // 3. Compute the new global Task state and write it (bumps version — write-path only).
      const taskUpdate: Partial<Task> = {
        updatedAt: now,
        version: (targetTask.version ?? 1) + 1,
      };

      if (updates.currentCount !== undefined) {
        taskUpdate.currentCount = updates.currentCount;
        if (targetTask.maxCount !== undefined) {
          const reached = updates.currentCount >= targetTask.maxCount;
          taskUpdate.isCompleted = reached;
          taskUpdate.completedAt = reached ? now : undefined;
        }
      }

      // Only apply isCompleted directly when currentCount hasn't already determined it.
      if (updates.isCompleted !== undefined && updates.currentCount === undefined) {
        taskUpdate.isCompleted = updates.isCompleted;
        taskUpdate.completedAt = updates.isCompleted ? now : undefined;
      }

      await db.tasks.update(targetTask.id, taskUpdate);

      // 4. Run the shared derivation pass — cascade to every affected board.
      const cascadeMap = await runBoardCascadeForTask(targetTask.id);

      // 5. Build TaskCompletionResult from the cascade map.
      const collateralBingosByBoard: Record<string, string[]> = {};
      for (const [affectedBoardId, entry] of cascadeMap) {
        if (affectedBoardId === boardId) {
          const totalSquares = primaryBoard.boardSize * primaryBoard.boardSize;
          result = {
            newBingos: entry.newBingos,
            lostBingos: entry.lostBingos,
            isGreenlog: entry.completedTasks >= totalSquares,
            boardCompleted: entry.boardCompleted,
            boardReactivated: entry.boardReactivated,
            collateralBingosByBoard, // re-attached below after the loop
          };
        } else if (entry.newBingos.length > 0) {
          collateralBingosByBoard[affectedBoardId] = entry.newBingos;
        }
      }

      // 6. Enqueue sync for the target Task (inside the transaction).
      const updatedTask = await db.tasks.get(targetTask.id);
      if (updatedTask) {
        await db.syncQueue.add({
          id: generateUUID(),
          entityType: 'tasks',
          entityId: targetTask.id,
          operationType: SyncOperationType.UPDATE,
          payload: JSON.stringify(updatedTask),
          status: SyncStatus.PENDING,
          retryCount: 0,
          createdAt: currentTimestamp(),
          priority: 0,
        });
      }

      // Populate collateralBingosByBoard on the result now that the loop is done.
      result.collateralBingosByBoard = collateralBingosByBoard;
    },
  );

  return result;
}
