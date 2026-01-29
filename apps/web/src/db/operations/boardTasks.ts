import { db } from '../database';
import type { BoardTask, CreateBoardTaskInput } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

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
  return boardTask;
}

/**
 * Complete a board task
 */
export async function completeBoardTask(id: string): Promise<void> {
  await db.boardTasks.update(id, {
    isCompleted: true,
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: db.boardTasks.get(id).then((bt) => (bt?.version ?? 0) + 1),
  });
}

/**
 * Uncomplete a board task
 */
export async function uncompleteBoardTask(id: string): Promise<void> {
  await db.boardTasks.update(id, {
    isCompleted: false,
    completedAt: undefined,
    updatedAt: currentTimestamp(),
    version: db.boardTasks.get(id).then((bt) => (bt?.version ?? 0) + 1),
  });
}

/**
 * Update counting task progress
 */
export async function updateCountingProgress(
  id: string,
  currentCount: number
): Promise<void> {
  const boardTask = await db.boardTasks.get(id);
  if (!boardTask) return;

  await db.boardTasks.update(id, {
    currentCount,
    isCompleted: currentCount >= (boardTask.currentCount ?? 0),
    completedAt:
      currentCount >= (boardTask.currentCount ?? 0) ? currentTimestamp() : undefined,
    updatedAt: currentTimestamp(),
    version: (boardTask.version ?? 0) + 1,
  });
}

/**
 * Update progress task step completion
 */
export async function updateProgressSteps(
  id: string,
  completedStepIds: string[]
): Promise<void> {
  await db.boardTasks.update(id, {
    completedStepIds,
    updatedAt: currentTimestamp(),
    version: db.boardTasks.get(id).then((bt) => (bt?.version ?? 0) + 1),
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
  return db.boardTasks.where('isAchievementSquare').equals(true).toArray();
}

/**
 * Find achievement squares for a specific timeframe
 */
export async function fetchAchievementSquaresByTimeframe(
  timeframe: string
): Promise<BoardTask[]> {
  return db.boardTasks
    .where('[isAchievementSquare+achievementTimeframe]')
    .equals([true, timeframe])
    .toArray();
}

/**
 * Find all boards using a specific task
 */
export async function fetchBoardsUsingTask(taskId: string): Promise<string[]> {
  const boardTasks = await db.boardTasks.where('taskId').equals(taskId).toArray();
  return [...new Set(boardTasks.map((bt) => bt.boardId))];
}
