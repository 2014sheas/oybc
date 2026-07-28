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
import {
  createBoardTask,
  removeBoardTaskFromBoard,
  updateBoardTaskAndCascade,
  reorderBoardTasks,
  addBoardTaskToBoard,
} from '../boardTasks';

/**
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Parts 3 + 4) — write-path
 * invariant guards + the sealed-board placement-mutator bypass fix.
 *
 * Part 3: `addBoardTaskToBoard`'s own guard rejections are covered in
 * `duplicatePlacementDivergence.test.ts` (they double as the fixed-behavior
 * pins for the diagnostic corruption scenario). This file covers
 * `createBoardTask`'s twin guards, plus the rearrange bounds guard.
 *
 * Part 4: `removeBoardTaskFromBoard` / `addBoardTaskToBoard` /
 * `updateBoardTaskAndCascade` previously wrote their placement mutation
 * unconditionally — a board sealed BETWEEN the caller's pre-txn reads and
 * the write transaction opening (the app-shell backstop can seal mid
 * edit-session) would still accept the mutation, silently bypassing "sealed
 * boards never mutate except via deterministic pull-path re-derivation."
 * Each mutator now re-fetches the OWNING board fresh inside its write txn
 * and refuses when it's missing/deleted/sealed — mirroring the
 * `updateBoardAndCascade` / `reorderBoardTasks` sealed-board guards #357
 * already shipped.
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

function seedTask(id: string, overrides: Partial<Task> = {}): Task {
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
    ...overrides,
  };
}

function seedPlacement(
  id: string,
  boardId: string,
  taskId: string,
  row: number,
  col: number,
  overrides: Partial<BoardTask> = {},
): BoardTask {
  return {
    id,
    boardId,
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

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

describe('createBoardTask — Part 3 write-path invariant guards', () => {
  it('rejects a placement colliding with a live row at the same cell', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await expect(
      createBoardTask({ boardId: 'board-1', taskId: 'task-B', row: 0, col: 0, isCenter: false }),
    ).rejects.toThrow(/already occupied/);
  });

  it('rejects placing a task already live elsewhere on the same board', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await expect(
      createBoardTask({ boardId: 'board-1', taskId: 'task-A', row: 1, col: 1, isCenter: false }),
    ).rejects.toThrow(/already placed on board/);
  });

  it('rejects a row/col outside the board grid', async () => {
    await db.boards.add(seedBoard({ boardSize: 3 }));
    await db.tasks.add(seedTask('task-A'));

    await expect(
      createBoardTask({ boardId: 'board-1', taskId: 'task-A', row: 0, col: 3, isCenter: false }),
    ).rejects.toThrow(/out of bounds/);
  });

  it('rejects when the owning board does not exist', async () => {
    await db.tasks.add(seedTask('task-A'));

    await expect(
      createBoardTask({ boardId: 'missing-board', taskId: 'task-A', row: 0, col: 0, isCenter: false }),
    ).rejects.toThrow(/not found/);
  });

  it('accepts a valid placement and writes it', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));

    const created = await createBoardTask({
      boardId: 'board-1',
      taskId: 'task-A',
      row: 0,
      col: 0,
      isCenter: false,
    });

    expect(created.id).toBeTruthy();
    const row = await db.boardTasks.get(created.id);
    expect(row?.taskId).toBe('task-A');
  });
});

describe('createBoardTask — PR-5 Item 3 isCenter uniqueness guard', () => {
  it('rejects a second isCenter: true placement when a live center row already exists', async () => {
    await db.boards.add(seedBoard({ centerSquareType: CenterSquareType.CHOSEN }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 1, 1, { isCenter: true }));

    await expect(
      createBoardTask({ boardId: 'board-1', taskId: 'task-B', row: 0, col: 2, isCenter: true }),
    ).rejects.toThrow(/already has a live center placement/);

    // Rejected — nothing written.
    expect(await db.boardTasks.where('boardId').equals('board-1').count()).toBe(1);
  });

  it('does NOT reject an isCenter: true placement when the existing center row is tombstoned', async () => {
    await db.boards.add(seedBoard({ centerSquareType: CenterSquareType.CHOSEN }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(
      seedPlacement('bt-A', 'board-1', 'task-A', 1, 1, { isCenter: true, isDeleted: true }),
    );

    const created = await createBoardTask({
      boardId: 'board-1',
      taskId: 'task-B',
      row: 1,
      col: 1,
      isCenter: true,
    });

    expect((await db.boardTasks.get(created.id))?.isCenter).toBe(true);
  });

  it('does NOT reject a non-center placement even when a live center row already exists', async () => {
    await db.boards.add(seedBoard({ centerSquareType: CenterSquareType.CHOSEN }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 1, 1, { isCenter: true }));

    const created = await createBoardTask({
      boardId: 'board-1',
      taskId: 'task-B',
      row: 0,
      col: 0,
      isCenter: false,
    });

    expect((await db.boardTasks.get(created.id))?.isCenter).toBe(false);
  });
});

describe('reorderBoardTasks — Part 3 bounds guard on staged move targets', () => {
  it('rejects the WHOLE batch when any staged target falls outside the board grid — no partial writes', async () => {
    await db.boards.add(seedBoard({ boardSize: 3 }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));
    await db.boardTasks.add(seedPlacement('bt-B', 'board-1', 'task-B', 0, 1));

    await expect(
      reorderBoardTasks('board-1', [
        { boardTaskId: 'bt-A', row: 1, col: 1 }, // valid
        { boardTaskId: 'bt-B', row: 3, col: 0 }, // out of bounds
      ]),
    ).rejects.toThrow(/out of bounds/);

    // Neither move was applied — bt-A stays at its ORIGINAL position too.
    expect((await db.boardTasks.get('bt-A'))?.row).toBe(0);
    expect((await db.boardTasks.get('bt-A'))?.col).toBe(0);
    expect((await db.boardTasks.get('bt-B'))?.row).toBe(0);
  });

  it('applies a batch whose every target is in bounds', async () => {
    await db.boards.add(seedBoard({ boardSize: 3 }));
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await reorderBoardTasks('board-1', [{ boardTaskId: 'bt-A', row: 2, col: 2 }]);

    const row = await db.boardTasks.get('bt-A');
    expect(row?.row).toBe(2);
    expect(row?.col).toBe(2);
  });
});

describe('Part 4 — sealed-board placement-mutator guards', () => {
  it('removeBoardTaskFromBoard refuses to tombstone a placement on a SEALED board', async () => {
    await db.boards.add(seedBoard({ status: BoardStatus.COMPLETED, sealedAt: '2026-06-15T00:00:00.000Z' }));
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await removeBoardTaskFromBoard('bt-A');

    const row = await db.boardTasks.get('bt-A');
    expect(row?.isDeleted).toBe(false); // untouched — the board is sealed
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('removeBoardTaskFromBoard refuses when the owning board is missing', async () => {
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'no-such-board', 'task-A', 0, 0));

    await removeBoardTaskFromBoard('bt-A');

    expect((await db.boardTasks.get('bt-A'))?.isDeleted).toBe(false);
  });

  it('removeBoardTaskFromBoard still tombstones normally on a non-sealed board (no regression)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await removeBoardTaskFromBoard('bt-A');

    expect((await db.boardTasks.get('bt-A'))?.isDeleted).toBe(true);
  });

  it('updateBoardTaskAndCascade refuses to swap a cell\'s task on a SEALED board', async () => {
    await db.boards.add(seedBoard({ status: BoardStatus.COMPLETED, sealedAt: '2026-06-15T00:00:00.000Z' }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await updateBoardTaskAndCascade('bt-A', 'task-B');

    const row = await db.boardTasks.get('bt-A');
    expect(row?.taskId).toBe('task-A'); // untouched — the board is sealed
    expect(row?.version).toBe(1);
  });

  it('updateBoardTaskAndCascade still swaps normally on a non-sealed board (no regression)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-B'));
    await db.boardTasks.add(seedPlacement('bt-A', 'board-1', 'task-A', 0, 0));

    await updateBoardTaskAndCascade('bt-A', 'task-B');

    expect((await db.boardTasks.get('bt-A'))?.taskId).toBe('task-B');
  });

  it('addBoardTaskToBoard (re-exercised here for Part 4) refuses to add onto a SEALED board', async () => {
    await db.boards.add(seedBoard({ status: BoardStatus.COMPLETED, sealedAt: '2026-06-15T00:00:00.000Z' }));
    await db.tasks.add(seedTask('task-A'));

    await expect(addBoardTaskToBoard('board-1', 'task-A', 0, 0)).rejects.toThrow(/sealed/);

    expect(await db.boardTasks.where('boardId').equals('board-1').count()).toBe(0);
  });
});
