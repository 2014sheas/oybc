import { db } from '../database';
import type { Board, CreateBoardInput } from '@oybc/shared';
import { BoardStatus, SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Board CRUD Operations
 */

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
  input: CreateBoardInput
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
  };

  await db.boards.add(board);
  void addToSyncQueue('boards', board.id, SyncOperationType.CREATE, board);
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
  if (updated) void addToSyncQueue('boards', id, SyncOperationType.UPDATE, updated);
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
  if (board) void addToSyncQueue('boards', id, SyncOperationType.DELETE, board);
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
  if (updatedBoard) void addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, updatedBoard);
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
  if (completedBoard) void addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, completedBoard);
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
  if (activated) void addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, activated);
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
