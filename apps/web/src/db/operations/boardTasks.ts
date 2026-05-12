import { db } from '../database';
import type { BoardTask, CreateBoardTaskInput } from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

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
