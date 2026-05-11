import { db } from '../database';
import type { BoardTask, CreateBoardTaskInput } from '@oybc/shared';
import { SyncOperationType, SyncStatus } from '@oybc/shared';
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
 * Create a board task (add task to board)
 *
 * Phase 6.3: enforces mutual exclusion between `referencedBoardId` and
 * `referencedTemplateId` defensively (Zod refinement is the primary
 * guard; this is belt-and-braces). Cycle detection happens in the UI
 * layer where the user can see the cyclePath; this helper assumes the
 * caller has already cleared a cycle check.
 */
export async function createBoardTask(
  input: CreateBoardTaskInput
): Promise<BoardTask> {
  if (input.referencedBoardId && input.referencedTemplateId) {
    throw new Error(
      'BoardTask.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }
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
    referencedBoardId: input.referencedBoardId,
    referencedTemplateId: input.referencedTemplateId,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
  };

  await db.boardTasks.add(boardTask);
  await addToSyncQueue('boardTasks', boardTask.id, SyncOperationType.CREATE, boardTask);
  return boardTask;
}

/**
 * Phase 6.3: update an existing BoardTask's achievement-square config.
 * The cycle-detection check lives in the UI layer (so the user gets the
 * cyclePath surfaced); this helper just enforces mutual exclusion and
 * persists the patch + sync queue entry.
 *
 * Pass `null` for either reference field to explicitly clear it (e.g.,
 * switching from specific-board mode back to aggregate). Undefined
 * leaves the existing value unchanged.
 */
export async function updateAchievementSquareConfig(
  id: string,
  patch: {
    isAchievementSquare?: boolean;
    achievementType?: 'bingo' | 'full_completion';
    achievementCount?: number;
    achievementTimeframe?: BoardTask['achievementTimeframe'];
    referencedBoardId?: string | null;
    referencedTemplateId?: string | null;
  },
): Promise<void> {
  const existing = await db.boardTasks.get(id);
  if (!existing) return;

  const nextRefBoard =
    patch.referencedBoardId === null
      ? undefined
      : patch.referencedBoardId ?? existing.referencedBoardId;
  const nextRefTemplate =
    patch.referencedTemplateId === null
      ? undefined
      : patch.referencedTemplateId ?? existing.referencedTemplateId;
  if (nextRefBoard && nextRefTemplate) {
    throw new Error(
      'BoardTask.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }

  const update: Partial<BoardTask> = {
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  if (patch.isAchievementSquare !== undefined) update.isAchievementSquare = patch.isAchievementSquare;
  if (patch.achievementType !== undefined) update.achievementType = patch.achievementType;
  if (patch.achievementCount !== undefined) update.achievementCount = patch.achievementCount;
  if (patch.achievementTimeframe !== undefined) update.achievementTimeframe = patch.achievementTimeframe;
  // `null` patch sentinel clears the field; `undefined` leaves it untouched.
  if (patch.referencedBoardId === null) {
    update.referencedBoardId = undefined;
  } else if (patch.referencedBoardId !== undefined) {
    update.referencedBoardId = patch.referencedBoardId;
  }
  if (patch.referencedTemplateId === null) {
    update.referencedTemplateId = undefined;
  } else if (patch.referencedTemplateId !== undefined) {
    update.referencedTemplateId = patch.referencedTemplateId;
  }

  // Atomic update + sync queue enqueue. Without the transaction a
  // crash between the row write and the queue insert would leave a
  // locally-updated cell with no sync entry — silent divergence
  // because the next push pass has nothing to send. Mirrors the iOS
  // `AppDatabase.updateAchievementSquareConfig` GRDB `write { }` block.
  await db.transaction('rw', [db.boardTasks, db.syncQueue], async () => {
    await db.boardTasks.update(id, update);
    const updated = await db.boardTasks.get(id);
    if (!updated) return;
    // Inline the sync-queue insert rather than calling addToSyncQueue
    // — that helper uses its own implicit transaction, and Dexie
    // doesn't let you nest transactions on the same connection.
    if (import.meta.env.DEV) {
      const userId = (updated as unknown as { userId?: string }).userId;
      if (userId === 'playground-user-1') return;
    }
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'boardTasks',
      entityId: id,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(updated),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  });
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
