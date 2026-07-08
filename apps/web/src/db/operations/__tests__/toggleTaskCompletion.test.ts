import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  SyncStatus,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { toggleTaskCompletionAndCascade } from '../tasks.crud';

/**
 * Covers `toggleTaskCompletionAndCascade` (issue #270, B2-W2) — the
 * relocated single-transaction completion-toggle op that used to be an
 * inline `db.transaction` fallback in `BoardPlaySurface.handleCompoundChildToggle`.
 *
 * Test-DB strategy: the ops under test import the real Dexie singleton
 * (`db` from `src/db/database.ts`), not an injectable instance, so there's
 * no way to point them at a separately-constructed `AppDatabase` — doing so
 * would just leave an unused instance sitting next to the one the code
 * under test actually uses. Instead:
 *   - `vitest.setup.ts` installs `fake-indexeddb/auto` globally, so the
 *     singleton's real Dexie schema (declared in `database.ts`) runs
 *     against an in-memory IndexedDB instead of a browser's.
 *   - Each test clears the handful of tables it touches in `afterEach`,
 *     giving full isolation between tests without needing to reconstruct
 *     the schema (10+ `.version().stores()` steps) per test.
 */

async function seedTask(overrides: Partial<Task> = {}): Promise<Task> {
  const task: Task = {
    id: 'task-1',
    userId: 'user-1',
    title: 'Read a book',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.tasks.add(task);
  return task;
}

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Test board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-01-01T00:00:00.000Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedBoardTask(overrides: Partial<BoardTask> = {}): Promise<BoardTask> {
  const boardTask: BoardTask = {
    id: 'bt-1',
    boardId: 'board-1',
    taskId: 'task-1',
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    ...overrides,
  };
  await db.boardTasks.add(boardTask);
  return boardTask;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.syncQueue.clear();
});

describe('toggleTaskCompletionAndCascade', () => {
  it('completes an incomplete task: sets isCompleted + completedAt, bumps version, enqueues sync, runs cascade', async () => {
    await seedTask({ isCompleted: false, version: 1 });
    await seedBoard({ completedTasks: 0 });
    await seedBoardTask();

    await toggleTaskCompletionAndCascade('task-1');

    const updatedTask = await db.tasks.get('task-1');
    expect(updatedTask?.isCompleted).toBe(true);
    expect(updatedTask?.completedAt).toBeTruthy();
    expect(updatedTask?.version).toBe(2);

    const syncRows = await db.syncQueue.toArray();
    const taskSyncRows = syncRows.filter(
      (r) => r.entityType === 'tasks' && r.entityId === 'task-1',
    );
    expect(taskSyncRows).toHaveLength(1);
    expect(taskSyncRows[0].operationType).toBe(SyncOperationType.UPDATE);
    expect(taskSyncRows[0].status).toBe(SyncStatus.PENDING);
    const payload = JSON.parse(taskSyncRows[0].payload as string) as Task;
    expect(payload.isCompleted).toBe(true);

    // Cascade ran: the board's denormalized completedTasks reflects the
    // newly-completed square (the only BoardTask placed on this board).
    const updatedBoard = await db.boards.get('board-1');
    expect(updatedBoard?.completedTasks).toBe(1);
  });

  it('un-completes a completed task: clears completedAt (per the inline fallback\'s unconditional latch), bumps version, enqueues sync, runs cascade', async () => {
    await seedTask({
      isCompleted: true,
      completedAt: '2026-01-02T00:00:00.000Z',
      version: 3,
    });
    await seedBoard({ completedTasks: 1, linesCompleted: 0 });
    await seedBoardTask();

    await toggleTaskCompletionAndCascade('task-1');

    const updatedTask = await db.tasks.get('task-1');
    expect(updatedTask?.isCompleted).toBe(false);
    expect(updatedTask?.completedAt).toBeUndefined();
    expect(updatedTask?.version).toBe(4);

    const syncRows = await db.syncQueue
      .filter((r) => r.entityType === 'tasks' && r.entityId === 'task-1')
      .toArray();
    expect(syncRows).toHaveLength(1);
    const payload = JSON.parse(syncRows[0].payload as string) as Task;
    expect(payload.isCompleted).toBe(false);
    expect(payload.completedAt).toBeUndefined();

    const updatedBoard = await db.boards.get('board-1');
    expect(updatedBoard?.completedTasks).toBe(0);
  });

  it('is a no-op when the task does not exist: no writes, no sync entry', async () => {
    await seedBoard({ completedTasks: 0 });
    // No task, no boardTask seeded — 'missing-task' has no row anywhere.

    await toggleTaskCompletionAndCascade('missing-task');

    expect(await db.tasks.get('missing-task')).toBeUndefined();
    const syncRows = await db.syncQueue.toArray();
    expect(syncRows).toHaveLength(0);
    // Board is untouched — the guard returns before the transaction (and
    // therefore before the cascade) ever runs.
    const board = await db.boards.get('board-1');
    expect(board?.completedTasks).toBe(0);
    expect(board?.version).toBe(1);
  });
});
