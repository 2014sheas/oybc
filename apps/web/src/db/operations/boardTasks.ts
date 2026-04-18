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
    void addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, bt);
  }
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
    isCompleted: false,
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
 * Complete a board task.
 *
 * @param id - The board task ID to mark as completed
 */
export async function completeBoardTask(id: string): Promise<void> {
  const bt = await db.boardTasks.get(id);
  if (!bt) return;
  await db.boardTasks.update(id, {
    isCompleted: true,
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (bt.version ?? 0) + 1,
  });
}

/**
 * Update counting task progress on a board task.
 *
 * Note: For game-loop interactions, prefer `handleTaskCompletion()` from
 * orchestration.ts which also handles bingo detection and board stats.
 *
 * @param id - The board task ID
 * @param currentCount - The new count value
 * @param maxCount - The task's maximum count (for completion detection)
 */
export async function updateCountingProgress(
  id: string,
  currentCount: number,
  maxCount: number,
): Promise<void> {
  const boardTask = await db.boardTasks.get(id);
  if (!boardTask) return;

  const isNowCompleted = currentCount >= maxCount;
  await db.boardTasks.update(id, {
    currentCount,
    isCompleted: isNowCompleted,
    completedAt: isNowCompleted ? currentTimestamp() : undefined,
    updatedAt: currentTimestamp(),
    version: (boardTask.version ?? 0) + 1,
  });
}

/**
 * Update progress task step completion on a board task.
 *
 * @param id - The board task ID
 * @param completedStepIds - Array of completed step IDs
 */
export async function updateProgressSteps(
  id: string,
  completedStepIds: string[]
): Promise<void> {
  const bt = await db.boardTasks.get(id);
  if (!bt) return;
  await db.boardTasks.update(id, {
    completedStepIds,
    updatedAt: currentTimestamp(),
    version: (bt.version ?? 0) + 1,
  });
}

/**
 * Complete a step in a progress task
 */
export async function completeProgressStep(
  boardTaskId: string,
  stepId: string
): Promise<void> {
  const boardTask = await db.boardTasks.get(boardTaskId);
  if (!boardTask) return;

  const completedStepIds = boardTask.completedStepIds || [];
  if (!completedStepIds.includes(stepId)) {
    completedStepIds.push(stepId);
    await updateProgressSteps(boardTaskId, completedStepIds);
  }
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

  const isComplete = progress >= (boardTask.achievementCount ?? 0);

  await db.boardTasks.update(id, {
    achievementProgress: progress,
    isCompleted: isComplete,
    completedAt: isComplete ? currentTimestamp() : undefined,
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
