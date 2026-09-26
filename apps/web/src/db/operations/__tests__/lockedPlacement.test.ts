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
import { reorderBoardTasks, setBoardTaskLocked } from '../boardTasks';

/**
 * Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) — per-square
 * locks at the write path: `setBoardTaskLocked` (version bump + enqueue,
 * idempotent, sealed guard) and `reorderBoardTasks`' locked-row guard (the
 * whole batch is refused, nothing partial).
 */

const USER = 'user-1';

function seedBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: USER,
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: '2026-06-01T00:00:00.000Z',
    centerSquareType: CenterSquareType.NONE,
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

function seedPlacement(id: string, taskId: string, row: number, col: number, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id,
    boardId: 'board-1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

async function seedTwo(lockA = false): Promise<void> {
  await db.boards.add(seedBoard());
  await db.tasks.add(seedTask('task-A'));
  await db.tasks.add(seedTask('task-B'));
  await db.boardTasks.add(seedPlacement('bt-A', 'task-A', 0, 0, lockA ? { isLocked: true } : {}));
  await db.boardTasks.add(seedPlacement('bt-B', 'task-B', 0, 1));
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

describe('setBoardTaskLocked', () => {
  it('locks a placement: version bump, updatedAt, sync enqueue', async () => {
    await seedTwo();
    await setBoardTaskLocked('bt-A', true);
    const row = await db.boardTasks.get('bt-A');
    expect(row?.isLocked).toBe(true);
    expect(row?.version).toBe(2);
    const queued = await db.syncQueue.filter((q) => q.entityId === 'bt-A').toArray();
    expect(queued.length).toBe(1);
  });

  it('is idempotent: setting the same state writes nothing', async () => {
    await seedTwo();
    await setBoardTaskLocked('bt-A', false); // already unlocked (field absent)
    const row = await db.boardTasks.get('bt-A');
    expect(row?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('unlocks a locked placement', async () => {
    await seedTwo(true);
    await setBoardTaskLocked('bt-A', false);
    expect((await db.boardTasks.get('bt-A'))?.isLocked).toBe(false);
  });

  it('refuses silently on a sealed board', async () => {
    await db.boards.add(seedBoard({ sealedAt: '2026-07-01T00:00:00.000Z', sealedCompletedCells: [] }));
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'task-A', 0, 0));
    await setBoardTaskLocked('bt-A', true);
    expect((await db.boardTasks.get('bt-A'))?.isLocked).toBeUndefined();
    expect(await db.syncQueue.count()).toBe(0);
  });
});

describe('reorderBoardTasks — locked-row guard', () => {
  it('rejects the whole batch when a staged move relocates a locked row — no partial writes', async () => {
    await seedTwo(true);
    await expect(
      reorderBoardTasks('board-1', [
        { boardTaskId: 'bt-B', row: 2, col: 2 },
        { boardTaskId: 'bt-A', row: 1, col: 1 },
      ]),
    ).rejects.toThrow(/locked in place/);
    const b = await db.boardTasks.get('bt-B');
    expect([b?.row, b?.col, b?.version]).toEqual([0, 1, 1]);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('accepts a batch that moves only unlocked rows', async () => {
    await seedTwo(true);
    await reorderBoardTasks('board-1', [{ boardTaskId: 'bt-B', row: 2, col: 2 }]);
    const b = await db.boardTasks.get('bt-B');
    expect([b?.row, b?.col]).toEqual([2, 2]);
    const a = await db.boardTasks.get('bt-A');
    expect([a?.row, a?.col, a?.isLocked]).toEqual([0, 0, true]);
  });

  it('accepts a locked row "move" to its own position (no-op entry)', async () => {
    await seedTwo(true);
    await expect(
      reorderBoardTasks('board-1', [{ boardTaskId: 'bt-A', row: 0, col: 0 }]),
    ).resolves.toBeUndefined();
  });
});
