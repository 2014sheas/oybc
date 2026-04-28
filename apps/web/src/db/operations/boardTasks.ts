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
 * Create a board task (add task to board)
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
    isAchievementSquare: input.isAchievementSquare,
    achievementType: input.achievementType,
    achievementCount: input.achievementCount,
    achievementTimeframe: input.achievementTimeframe,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
  };

  await db.boardTasks.add(boardTask);
  void addToSyncQueue('boardTasks', boardTask.id, SyncOperationType.CREATE, boardTask);
  return boardTask;
}

/**
 * Update achievement square progress
 */
export async function updateAchievementProgress(
  id: string,
  progress: number
): Promise<void> {
  const boardTask = await db.boardTasks.get(id);
  if (!boardTask || !boardTask.isAchievementSquare) return;

  await db.boardTasks.update(id, {
    achievementProgress: progress,
    updatedAt: currentTimestamp(),
    version: (boardTask.version ?? 0) + 1,
  });
}

/**
 * Find all achievement squares across all boards
 */
export async function fetchAchievementSquares(): Promise<BoardTask[]> {
  // Dexie types `.equals()` against `IndexableType` which excludes
  // booleans, but IndexedDB coerces booleans to 1/0 at runtime.
  return db.boardTasks.where('isAchievementSquare').equals(true as unknown as string).toArray();
}

/**
 * Find achievement squares for a specific timeframe
 */
export async function fetchAchievementSquaresByTimeframe(
  timeframe: string
): Promise<BoardTask[]> {
  return db.boardTasks
    .where('[isAchievementSquare+achievementTimeframe]')
    // Dexie's `.equals()` doesn't model compound-index tuples in its
    // type signature (only scalar IndexableType).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    .equals([true, timeframe] as any)
    .toArray();
}

/**
 * Find all boards using a specific task
 */
export async function fetchBoardsUsingTask(taskId: string): Promise<string[]> {
  const boardTasks = await db.boardTasks.where('taskId').equals(taskId).toArray();
  return [...new Set(boardTasks.map((bt) => bt.boardId))];
}
