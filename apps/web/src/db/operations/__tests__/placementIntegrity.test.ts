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
import { repairPlacementIntegrity } from '../placementIntegrity';

/**
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 1) —
 * `repairPlacementIntegrity`: the app-open self-heal PRE-step that
 * tombstones ALREADY-corrupted BoardTask placement rows (duplicate-cell,
 * duplicate-task, out-of-bounds) via the shared, deterministic
 * `computePlacementIntegrityRepair` core. See `packages/shared/tests/algorithms/placementResolution.test.ts`
 * for the winner-rule vector coverage this pass delegates to;
 * `duplicatePlacementDivergence.test.ts` for the render/derivation
 * divergence this repair (plus Part 2's `resolvePlacements`) fixes.
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

async function syncEntriesFor(entityType: string, entityId: string) {
  return (await db.syncQueue.toArray()).filter(
    (i) => i.entityType === entityType && i.entityId === entityId,
  );
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

describe('repairPlacementIntegrity', () => {
  it('is a zero-write no-op on a clean board', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-a', 'board-1', 'task-A', 0, 0));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual([]);
    const row = await db.boardTasks.get('bt-a');
    expect(row?.isDeleted).toBe(false);
    expect(row?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('tombstones the losing row of a cell collision (winner rule: highest version)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual(['board-1']);
    const loser = await db.boardTasks.get('bt-a-old');
    expect(loser?.isDeleted).toBe(true);
    expect(loser?.deletedAt).toBeTruthy();
    expect(loser?.version).toBe(2); // bumped from 1
    const winner = await db.boardTasks.get('bt-d-new');
    expect(winner?.isDeleted).toBe(false);
    expect(winner?.version).toBe(2); // unchanged — the survivor is never touched
  });

  it('tombstones the losing row of a same-task duplicate on two non-colliding cells', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(
      seedPlacement('bt-A-old', 'board-1', 'task-A', 0, 0, { version: 1, updatedAt: '2026-05-01T00:00:00.000Z' }),
    );
    await db.boardTasks.add(
      seedPlacement('bt-A-new', 'board-1', 'task-A', 2, 2, { version: 1, updatedAt: '2026-06-01T00:00:00.000Z' }),
    );

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual(['board-1']);
    expect((await db.boardTasks.get('bt-A-old'))?.isDeleted).toBe(true);
    expect((await db.boardTasks.get('bt-A-new'))?.isDeleted).toBe(false);
  });

  it('tombstones an out-of-bounds row unconditionally, even carrying the highest version', async () => {
    await db.boards.add(seedBoard({ boardSize: 3 }));
    await db.tasks.add(seedTask('task-A'));
    await db.boardTasks.add(seedPlacement('bt-oob', 'board-1', 'task-A', 7, 0, { version: 99 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual(['board-1']);
    expect((await db.boardTasks.get('bt-oob'))?.isDeleted).toBe(true);
  });

  it('enqueues a sync DELETE with the fresh tombstoned payload for every repaired row', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    await repairPlacementIntegrity(USER);

    const entries = await syncEntriesFor('boardTasks', 'bt-a-old');
    expect(entries).toHaveLength(1);
    const payload = JSON.parse(entries[0].payload) as BoardTask;
    expect(payload.isDeleted).toBe(true);
    expect(payload.version).toBe(2);
    // The winner never gets a sync entry — it wasn't touched.
    expect(await syncEntriesFor('boardTasks', 'bt-d-new')).toHaveLength(0);
  });

  it('is idempotent — a second run on the already-repaired board writes nothing further', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    const first = await repairPlacementIntegrity(USER);
    expect(first).toEqual(['board-1']);
    await db.syncQueue.clear(); // isolate the second run's effect

    const second = await repairPlacementIntegrity(USER);

    expect(second).toEqual([]);
    expect(await db.syncQueue.count()).toBe(0);
    // Winner's version is unchanged by the second pass (would bump if it
    // were mistakenly re-tombstoned or re-touched).
    expect((await db.boardTasks.get('bt-d-new'))?.version).toBe(2);
  });

  it('does NOT touch the board row itself — no stats/version rewrite (that is reDeriveActiveBoards\' job)', async () => {
    await db.boards.add(seedBoard({ completedTasks: 0, version: 5 }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    await repairPlacementIntegrity(USER);

    const board = await db.boards.get('board-1');
    expect(board?.version).toBe(5); // unchanged
    expect(board?.completedTasks).toBe(0); // unchanged — no stats rewrite here
    expect(await syncEntriesFor('boards', 'board-1')).toHaveLength(0);
  });

  it('repairs a SEALED board\'s live placement rows too — scope is every status', async () => {
    await db.boards.add(
      seedBoard({ status: BoardStatus.COMPLETED, sealedAt: '2026-06-15T00:00:00.000Z', version: 3 }),
    );
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual(['board-1']);
    expect((await db.boardTasks.get('bt-a-old'))?.isDeleted).toBe(true);
    // The sealed board's OWN row (status/version/sealedAt) is untouched —
    // this pass never rewrites a sealed snapshot; only the deterministic
    // pull-path re-derivation (sealing.ts) is allowed to.
    const board = await db.boards.get('board-1');
    expect(board?.version).toBe(3);
    expect(board?.sealedAt).toBe('2026-06-15T00:00:00.000Z');
  });

  it('scopes to the given userId only — a board owned by another user is untouched', async () => {
    await db.boards.add(seedBoard({ id: 'board-other', userId: 'user-2' }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-other', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-other', 'task-D', 0, 0, { version: 2 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual([]);
    expect((await db.boardTasks.get('bt-a-old'))?.isDeleted).toBe(false);
  });

  it('skips a deleted board entirely', async () => {
    await db.boards.add(seedBoard({ isDeleted: true, deletedAt: '2026-06-01T00:00:00.000Z' }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-a-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-d-new', 'board-1', 'task-D', 0, 0, { version: 2 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(repairedIds).toEqual([]);
    expect((await db.boardTasks.get('bt-a-old'))?.isDeleted).toBe(false);
  });

  it('repairs multiple corrupted boards in one pass, each independently', async () => {
    await db.boards.add(seedBoard({ id: 'board-1' }));
    await db.boards.add(seedBoard({ id: 'board-2' }));
    await db.tasks.add(seedTask('task-A'));
    await db.tasks.add(seedTask('task-D'));
    await db.boardTasks.add(seedPlacement('bt-1-old', 'board-1', 'task-A', 0, 0, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-1-new', 'board-1', 'task-D', 0, 0, { version: 2 }));
    await db.boardTasks.add(seedPlacement('bt-2-old', 'board-2', 'task-A', 1, 1, { version: 1 }));
    await db.boardTasks.add(seedPlacement('bt-2-new', 'board-2', 'task-D', 1, 1, { version: 2 }));

    const repairedIds = await repairPlacementIntegrity(USER);

    expect(new Set(repairedIds)).toEqual(new Set(['board-1', 'board-2']));
    expect((await db.boardTasks.get('bt-1-old'))?.isDeleted).toBe(true);
    expect((await db.boardTasks.get('bt-2-old'))?.isDeleted).toBe(true);
  });
});
