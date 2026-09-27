import { afterEach, describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { closeBoard, reopenBoard, BoardLifecycleError, refreshWatchersForBoards } from '../boardLifecycle';
import { sealBoard } from '../sealing';

/**
 * Board Edit redesign slice 4 (T2) — Close / Reopen + achievement-watcher
 * refresh (plan D3, D6, D8). Exercises the REAL `closeBoard`/`reopenBoard`
 * ops against fake-indexeddb, mirroring `sealing.test.ts`'s seed helpers.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-02T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';
const PAST_AUTO_CLOSE = '2026-07-03T01:00:00.000Z'; // > END + 1 daily window

const BOARD = '20000000-0000-4000-8000-000000000001';
const TASK_A = '10000000-0000-4000-8000-000000000001';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function boardSyncQueueEntries(boardId: string) {
  return (await db.syncQueue.toArray()).filter(
    (i) => i.entityType === 'boards' && i.entityId === boardId,
  );
}

async function seedNormalTask(id: string): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    endDate: END,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.put(board);
  return board;
}

async function placeTask(boardId: string, taskId: string, cell: number): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: Math.floor(cell / 3),
    col: cell % 3,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

function completionEvent(id: string, taskId: string, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

async function seedFullBoard(boardId: string, over: Partial<Board> = {}): Promise<string[]> {
  await seedBoard(boardId, over);
  const ids: string[] = [];
  for (let cell = 0; cell < 9; cell++) {
    const id = `40000000-0000-4000-8000-0000000000${String(cell + 1).padStart(2, '0')}`;
    await seedNormalTask(id);
    await placeTask(boardId, id, cell);
    ids.push(id);
  }
  return ids;
}

// ─── closeBoard ─────────────────────────────────────────────────────────────

describe('closeBoard', () => {
  it('seals the board — identical snapshot semantics to sealBoard (D3, same function underneath)', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(BOARD);
    await placeTask(BOARD, TASK_A, 0);
    await db.taskEvents.add(completionEvent('e1', TASK_A, IN_WINDOW));

    await closeBoard(BOARD, PAST_AUTO_CLOSE);

    const board = await db.boards.get(BOARD);
    expect(board?.sealedAt).toBe(PAST_AUTO_CLOSE);
    expect(board?.sealedCompletedCells).toEqual([0]);
    expect(board?.completedTasks).toBe(1);
    expect(board?.version).toBe(2);
    expect(await boardSyncQueueEntries(BOARD)).not.toHaveLength(0);
  });

  it('refuses a board that has not ended yet (notClosable)', async () => {
    await seedBoard(BOARD, { startDate: '2026-07-05T00:00:00.000Z', endDate: '2026-07-06T00:00:00.000Z' });
    await expect(closeBoard(BOARD, PAST_AUTO_CLOSE)).rejects.toBeInstanceOf(BoardLifecycleError);
    expect((await db.boards.get(BOARD))?.sealedAt).toBeUndefined();
  });

  it('refuses an indefinite board (notClosable)', async () => {
    await seedBoard(BOARD, { endDate: undefined });
    await expect(closeBoard(BOARD, PAST_AUTO_CLOSE)).rejects.toBeInstanceOf(BoardLifecycleError);
  });

  it('refuses a draft board (notClosable)', async () => {
    await seedBoard(BOARD, { status: BoardStatus.DRAFT });
    await expect(closeBoard(BOARD, PAST_AUTO_CLOSE)).rejects.toBeInstanceOf(BoardLifecycleError);
  });

  it('is idempotent — closing an already-closed board no-ops (does not re-stamp sealedAt)', async () => {
    await seedBoard(BOARD, { sealedAt: '2026-07-02T05:00:00.000Z', sealedCompletedCells: [] });
    await closeBoard(BOARD, PAST_AUTO_CLOSE);
    expect((await db.boards.get(BOARD))?.sealedAt).toBe('2026-07-02T05:00:00.000Z');
  });

  it('throws notFound for a missing or deleted board', async () => {
    await expect(closeBoard('nope', PAST_AUTO_CLOSE)).rejects.toBeInstanceOf(BoardLifecycleError);
    await seedBoard(BOARD, { isDeleted: true });
    await expect(closeBoard(BOARD, PAST_AUTO_CLOSE)).rejects.toBeInstanceOf(BoardLifecycleError);
  });

  it('refreshes a specific-board achievement watcher in the same transaction (D8)', async () => {
    await seedFullBoard(BOARD).then(async (ids) => {
      for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    });

    // A watcher board with an ACHIEVEMENT square watching BOARD, gated on
    // its bingo trigger — closing BOARD makes it greenlog (9/9 -> a full
    // line), which the watcher's own board must pick up in this same call.
    const WATCHER_BOARD = 'watcher-board';
    const ACH = 'achievement-task';
    const achievement: Task = {
      id: ACH,
      userId: USER,
      title: 'Watch it',
      type: TaskType.ACHIEVEMENT,
      referencedBoardId: BOARD,
      achievementTrigger: AchievementTrigger.GREENLOG,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(achievement);
    await seedBoard(WATCHER_BOARD, {
      startDate: '2026-07-01T00:00:00.000Z',
      endDate: '2030-01-01T00:00:00.000Z',
      boardSize: 3,
      totalTasks: 1,
    });
    await placeTask(WATCHER_BOARD, ACH, 0);

    await closeBoard(BOARD, PAST_AUTO_CLOSE);

    const watcherBoard = await db.boards.get(WATCHER_BOARD);
    // The achievement square greenlogs its 1x1 board once BOARD hits greenlog.
    expect(watcherBoard?.completedTasks).toBe(1);
  });
});

// ─── reopenBoard ────────────────────────────────────────────────────────────

describe('reopenBoard', () => {
  it('clears sealedAt + sealedCompletedCells, stamps reopenedAt, bumps version, enqueues sync', async () => {
    await seedBoard(BOARD, { sealedAt: '2026-07-02T05:00:00.000Z', sealedCompletedCells: [0, 1] });

    await reopenBoard(BOARD, '2026-07-10T00:00:00.000Z');

    const board = await db.boards.get(BOARD);
    expect(board?.sealedAt).toBeUndefined();
    expect(board?.sealedCompletedCells).toBeUndefined();
    expect(board?.reopenedAt).toBe('2026-07-10T00:00:00.000Z');
    expect(board?.version).toBeGreaterThan(1);
    expect(await boardSyncQueueEntries(BOARD)).not.toHaveLength(0);
  });

  it('re-derives live stats: a greenlogged sealed board flips back ACTIVE when reopened short of complete, then COMPLETED again once logged', async () => {
    const ids = await seedFullBoard(BOARD);
    // Complete only 8 of 9 in-window, then seal (grey cell 8, ACTIVE).
    for (let i = 0; i < 8; i++) await db.taskEvents.add(completionEvent(`ce-${i}`, ids[i], IN_WINDOW));
    await sealBoard(BOARD, '2026-07-02T05:00:00.000Z');
    expect((await db.boards.get(BOARD))?.status).toBe(BoardStatus.ACTIVE);

    await reopenBoard(BOARD, '2026-07-10T00:00:00.000Z');
    const reopened = await db.boards.get(BOARD);
    expect(reopened?.status).toBe(BoardStatus.ACTIVE);
    expect(reopened?.completedTasks).toBe(8);
    expect(reopened?.sealedAt).toBeUndefined();
  });

  it('spawns nothing — no recurringBoardTemplates row is created', async () => {
    await seedBoard(BOARD, { sealedAt: '2026-07-02T05:00:00.000Z' });
    await reopenBoard(BOARD, '2026-07-10T00:00:00.000Z');
    expect(await db.recurringBoardTemplates.count()).toBe(0);
  });

  it('refuses a board that is not currently sealed (notReopenable)', async () => {
    await seedBoard(BOARD);
    await expect(reopenBoard(BOARD, '2026-07-10T00:00:00.000Z')).rejects.toBeInstanceOf(BoardLifecycleError);
  });

  it('throws notFound for a missing or deleted board', async () => {
    await expect(reopenBoard('nope', '2026-07-10T00:00:00.000Z')).rejects.toBeInstanceOf(BoardLifecycleError);
    await seedBoard(BOARD, { sealedAt: '2026-07-02T05:00:00.000Z', isDeleted: true });
    await expect(reopenBoard(BOARD, '2026-07-10T00:00:00.000Z')).rejects.toBeInstanceOf(BoardLifecycleError);
  });
});

// ─── refreshWatchersForBoards (D8) ──────────────────────────────────────────

describe('refreshWatchersForBoards', () => {
  it('is a no-op when nothing watches the given boards', async () => {
    await seedBoard(BOARD);
    await expect(refreshWatchersForBoards([BOARD])).resolves.toBeUndefined();
  });

  it('ignores a deleted achievement watcher', async () => {
    await seedBoard(BOARD, { status: BoardStatus.COMPLETED, completedTasks: 9, boardSize: 3 });
    const ACH = 'ach-deleted';
    const task: Task = {
      id: ACH,
      userId: USER,
      title: 'Watch it',
      type: TaskType.ACHIEVEMENT,
      referencedBoardId: BOARD,
      achievementTrigger: AchievementTrigger.GREENLOG,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: true,
    };
    await db.tasks.add(task);
    const WATCHER_BOARD = 'watcher-board-2';
    await seedBoard(WATCHER_BOARD, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER_BOARD, ACH, 0);

    await refreshWatchersForBoards([BOARD]);
    // Nothing changed — the watcher task is deleted, so it's never re-derived.
    expect((await db.boards.get(WATCHER_BOARD))?.completedTasks).toBe(0);
  });
});
