import { db } from '../database';
import type { Board, CreateBoardInput } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Board CRUD Operations
 */

/**
 * Fetch all boards for a user (excluding deleted)
 */
export async function fetchBoards(userId: string): Promise<Board[]> {
  return db.boards
    .where('[userId+isDeleted]')
    .equals([userId, false])
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
  input: CreateBoardInput
): Promise<Board> {
  const board: Board = {
    id: generateUUID(),
    userId,
    name: input.name,
    description: input.description,
    status: 'draft',
    boardSize: input.boardSize,
    timeframe: input.timeframe,
    startDate: input.startDate,
    endDate: input.endDate,
    centerSquareType: input.centerSquareType,
    isRandomized: input.isRandomized,
    totalTasks: input.boardSize * input.boardSize,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.boards.add(board);
  return board;
}

/**
 * Update a board
 */
export async function updateBoard(
  id: string,
  updates: Partial<Board>
): Promise<void> {
  await db.boards.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: db.boards.get(id).then((b) => (b?.version ?? 0) + 1),
  });
}

/**
 * Soft delete a board
 */
export async function deleteBoard(id: string): Promise<void> {
  await db.boards.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
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
  await db.boards.update(boardId, {
    ...stats,
    updatedAt: currentTimestamp(),
    version: db.boards.get(boardId).then((b) => (b?.version ?? 0) + 1),
  });
}

/**
 * Mark board as completed
 */
export async function completeBoard(boardId: string): Promise<void> {
  await db.boards.update(boardId, {
    status: 'completed',
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: db.boards.get(boardId).then((b) => (b?.version ?? 0) + 1),
  });
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
    .equals([userId, timeframe, 'completed'])
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
      [userId, timeframe, 1],
      [userId, timeframe, Infinity]
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
    .where('[userId+isDeleted]')
    .equals([userId, false])
    .filter((b) => b.timeframe === timeframe && b.status === 'completed')
    .count();
}
