import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { normalizeLegacyChosenCenter } from '../boardTasks';
import { BoardNotEditableError } from '../boards';

/**
 * Board Edit slice 3 (D2) — `normalizeLegacyChosenCenter`: the on-disk
 * legacy CHOSEN board converts to NONE + (optionally) locked center
 * placement as an AUTHORED write on the user's next squares Save.
 * Mirrors iOS `LegacyChosenCenterTests.swift`.
 */

const USER = 'user-1';
const BOARD = 'board-1';

function seedBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: BOARD,
    userId: USER,
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: '2026-06-01T00:00:00.000Z',
    centerSquareType: CenterSquareType.CHOSEN,
    centerTaskId: 'task-C',
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function seedTask(id: string): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

function seedPlacement(id: string, taskId: string, row: number, col: number, isCenter = false): BoardTask {
  return {
    id,
    boardId: BOARD,
    taskId,
    row,
    col,
    isCenter,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

async function seed(board: Partial<Board> = {}): Promise<void> {
  await db.boards.add(seedBoard(board));
  await db.tasks.add(seedTask('task-C'));
  await db.tasks.add(seedTask('task-A'));
  await db.boardTasks.add(seedPlacement('bt-C', 'task-C', 1, 1, true));
  await db.boardTasks.add(seedPlacement('bt-A', 'task-A', 0, 0));
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

describe('normalizeLegacyChosenCenter', () => {
  it('converts a CHOSEN board to NONE and locks the center placement (version bumps + 2 queue rows)', async () => {
    await seed();
    await db.transaction('rw', [db.boards, db.boardTasks, db.syncQueue], () =>
      normalizeLegacyChosenCenter(BOARD, true),
    );

    const board = await db.boards.get(BOARD);
    expect(board?.centerSquareType).toBe(CenterSquareType.NONE);
    expect(board?.centerTaskId).toBeUndefined();
    expect(board?.version).toBe(2);

    const center = await db.boardTasks.get('bt-C');
    expect(center?.isLocked).toBe(true);
    expect(center?.isCenter).toBe(false);
    expect(center?.version).toBe(2);
    expect(center?.taskId).toBe('task-C');

    // An unrelated placement is untouched.
    expect((await db.boardTasks.get('bt-A'))?.version).toBe(1);

    const queued = await db.syncQueue.toArray();
    expect(queued.map((q) => `${q.entityType}:${q.entityId}`).sort()).toEqual([
      'boardTasks:bt-C',
      'boards:board-1',
    ]);
  });

  it('keepLocked:false leaves the center placement unlocked (still clears isCenter)', async () => {
    await seed();
    await normalizeLegacyChosenCenter(BOARD, false);
    const center = await db.boardTasks.get('bt-C');
    expect(center?.isLocked).toBe(false);
    expect(center?.isCenter).toBe(false);
    expect((await db.boards.get(BOARD))?.centerSquareType).toBe(CenterSquareType.NONE);
    expect(await db.syncQueue.count()).toBe(2);
  });

  it.each([CenterSquareType.NONE, CenterSquareType.FREE])('is a no-op on a %s board', async (type) => {
    await seed({ centerSquareType: type, centerTaskId: undefined });
    await normalizeLegacyChosenCenter(BOARD, true);
    expect((await db.boards.get(BOARD))?.version).toBe(1);
    expect((await db.boardTasks.get('bt-C'))?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('throws BoardNotEditableError on a sealed board and writes nothing', async () => {
    await seed({ sealedAt: '2026-07-01T00:00:00.000Z', sealedCompletedCells: [] });
    await expect(normalizeLegacyChosenCenter(BOARD, true)).rejects.toBeInstanceOf(
      BoardNotEditableError,
    );
    const board = await db.boards.get(BOARD);
    expect(board?.centerSquareType).toBe(CenterSquareType.CHOSEN);
    expect(board?.version).toBe(1);
    expect((await db.boardTasks.get('bt-C'))?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('converts the board row even when the center placement is missing', async () => {
    await db.boards.add(seedBoard());
    await normalizeLegacyChosenCenter(BOARD, true);
    expect((await db.boards.get(BOARD))?.centerSquareType).toBe(CenterSquareType.NONE);
    expect(await db.syncQueue.count()).toBe(1);
  });
});
