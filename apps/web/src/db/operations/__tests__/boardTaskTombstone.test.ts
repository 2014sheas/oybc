import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  resolveConflict,
  type Board,
  type BoardTask,
  type SyncableEntity,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { removeBoardTaskFromBoard } from '../boardTasks';
import { applyRemoteSubdoc } from '../pullApply';
import { runMigrationV17 } from '../migrationV17';

/**
 * Board-integrity PR-1 (docs/BOARD_INTEGRITY.md, issue #358) — durable
 * BoardTask deletes (tombstones) + the boardTasks-pull cascade.
 *
 * Root defect (found by 3 independent audit traces): `BoardTask` was the
 * ONLY synced collection without `isDeleted`. Placement "delete" was a
 * physical Dexie delete + a DELETE sync entry carrying the STALE pre-delete
 * snapshot (same version as the already-synced remote copy). At push time,
 * `resolveConflict` sees an exact version tie and — per SYNC_STRATEGY.md
 * rule 3 — remote wins, so the safety-net pull `table.put`s the row BACK
 * locally, self-reverting the delete within ~500ms. Secondary gap: a pulled
 * `boardTasks` row (live or tombstone) triggered NO board re-derivation, so
 * a receiving device's positional `completedLineIds` went stale after a
 * remote rearrange, and a pulled tombstone left the removed cell counted in
 * `completedTasks` until some unrelated cascade happened to touch the
 * board.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';

// Non-UUID ids are fine for direct db.* calls (Dexie doesn't validate
// shape), but `applyRemoteSubdoc` runs pulled docs through the Zod schema,
// which enforces `.uuid()` on id/boardId/taskId — those tests use these.
const BOARD = '20000000-0000-4000-8000-000000000001';
const TASK_A = '40000000-0000-4000-8000-000000000001';
const TASK_B = '40000000-0000-4000-8000-000000000002';
const TASK_C = '40000000-0000-4000-8000-000000000003';
const BT_A = '30000000-0000-4000-8000-000000000001';
const BT_B = '30000000-0000-4000-8000-000000000002';
const BT_C = '30000000-0000-4000-8000-000000000003';

function seedTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/** A NORMAL task plus a completion TaskEvent inside the board's window —
 *  Windowed Completion derives board-grid state from events, NOT from the
 *  Task's lifetime `isCompleted` cache, so a placement only renders/counts
 *  as complete when a real in-window event backs it (docs/WINDOWED_COMPLETION.md). */
async function seedWindowedCompleteTask(id: string): Promise<void> {
  await db.tasks.add(seedTask(id));
  const event: TaskEvent = {
    id: `${id}-ev`,
    userId: USER,
    taskId: id,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
}

function seedBoard(id: string, overrides: Partial<Board> = {}): Board {
  return {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
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
    ...overrides,
  };
}

function seedBoardTask(
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
    createdAt: START,
    updatedAt: START,
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
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('removeBoardTaskFromBoard — soft delete / tombstone conversion', () => {
  it('the row survives in Dexie as a tombstone (isDeleted, deletedAt, version bumped) instead of being physically removed', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await db.boards.add(seedBoard(BOARD));
    await db.boardTasks.add(seedBoardTask(BT_A, BOARD, TASK_A, 0, 0));

    await removeBoardTaskFromBoard(BT_A);

    const row = await db.boardTasks.get(BT_A);
    expect(row).toBeDefined();
    expect(row?.isDeleted).toBe(true);
    expect(row?.deletedAt).toBeTruthy();
    expect(row?.version).toBe(2);
  });

  it('enqueues the sync DELETE with the FRESH tombstoned payload (version bumped), not the stale pre-delete snapshot', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await db.boards.add(seedBoard(BOARD));
    await db.boardTasks.add(seedBoardTask(BT_A, BOARD, TASK_A, 0, 0));

    await removeBoardTaskFromBoard(BT_A);

    const entries = await syncEntriesFor('boardTasks', BT_A);
    expect(entries).toHaveLength(1);
    const payload = JSON.parse(entries[0].payload) as BoardTask;
    expect(payload.isDeleted).toBe(true);
    expect(payload.version).toBe(2); // NOT the stale version:1 pre-delete snapshot.
  });

  it('is a no-op on an already-tombstoned row (no double version bump, no duplicate sync entry)', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await db.boards.add(seedBoard(BOARD));
    await db.boardTasks.add(seedBoardTask(BT_A, BOARD, TASK_A, 0, 0));

    await removeBoardTaskFromBoard(BT_A);
    await db.syncQueue.clear(); // isolate the second call's effect
    await removeBoardTaskFromBoard(BT_A);

    const row = await db.boardTasks.get(BT_A);
    expect(row?.version).toBe(2); // unchanged by the second call
    const entries = await syncEntriesFor('boardTasks', BT_A);
    expect(entries).toHaveLength(0);
  });

  it('board stats recompute WITHOUT the tombstoned cell in the same call', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await seedWindowedCompleteTask(TASK_B);
    await db.boards.add(seedBoard(BOARD, { completedTasks: 2, version: 1 }));
    await db.boardTasks.add(seedBoardTask(BT_A, BOARD, TASK_A, 0, 0));
    await db.boardTasks.add(seedBoardTask(BT_B, BOARD, TASK_B, 0, 1));

    await removeBoardTaskFromBoard(BT_A);

    const board = await db.boards.get(BOARD);
    expect(board?.completedTasks).toBe(1); // A's cell no longer counts.
  });

  // ─── THE HEADLINE REGRESSION ────────────────────────────────────────────
  //
  // Pin the LWW tie-break flip that is the actual root fix. Before this PR,
  // the DELETE payload was the stale pre-delete row (same version as the
  // already-synced remote copy) — an exact version tie resolves to REMOTE
  // per `resolveConflict`'s rule 3, so the safety-net pull would `put` the
  // live remote row back locally, undoing the delete. After this PR, the
  // payload's version is bumped past the remote's, so LOCAL wins the same
  // comparison unconditionally — this is what makes the delete actually
  // stick.
  it('the tombstone payload wins resolveConflict against the still-live remote copy (tie-break flip)', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await db.boards.add(seedBoard(BOARD));
    // "Already synced": local row at version 1, matching what remote holds.
    const synced = seedBoardTask(BT_A, BOARD, TASK_A, 0, 0, { lastSyncedAt: START });
    await db.boardTasks.add(synced);

    // The remote copy is the exact pre-delete snapshot — same version, same
    // updatedAt (an exact tie, the worst case for the old payload).
    const remoteLive: SyncableEntity = { ...synced } as unknown as SyncableEntity;

    await removeBoardTaskFromBoard(BT_A);

    const entries = await syncEntriesFor('boardTasks', BT_A);
    const tombstonePayload = JSON.parse(entries[0].payload) as unknown as SyncableEntity;

    const resolution = resolveConflict(tombstonePayload, remoteLive);
    expect(resolution.winner).toBe('local');

    // Sanity-check the OLD (pre-fix) shape really would have lost: pushing
    // the untouched pre-delete snapshot as the "delete" payload ties exactly
    // and remote wins — which is the self-revert bug.
    const staleShapePayload: SyncableEntity = { ...synced } as unknown as SyncableEntity;
    const staleResolution = resolveConflict(staleShapePayload, remoteLive);
    expect(staleResolution.winner).toBe('remote');
  });
});

describe('applyRemoteSubdoc — boardTasks pull cascade (Board-integrity PR-1)', () => {
  it('applying a remote tombstone removes the cell from derived board stats in the same call', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await seedWindowedCompleteTask(TASK_B);
    await db.boards.add(seedBoard(BOARD, { completedTasks: 2, version: 1 }));
    const localA = seedBoardTask(BT_A, BOARD, TASK_A, 0, 0);
    await db.boardTasks.add(localA);
    await db.boardTasks.add(seedBoardTask(BT_B, BOARD, TASK_B, 0, 1));

    const remoteTombstone: BoardTask = {
      ...localA,
      isDeleted: true,
      deletedAt: START,
      version: 2,
      updatedAt: '2026-07-01T13:00:00.000Z',
    };

    const status = await applyRemoteSubdoc('boardTasks', remoteTombstone, USER);
    expect(status).toMatch(/^Pulled /);

    const row = await db.boardTasks.get(BT_A);
    expect(row?.isDeleted).toBe(true);

    const board = await db.boards.get(BOARD);
    expect(board?.completedTasks).toBe(1); // recomputed WITHOUT bt-a's cell.
    expect(board?.version).toBe(2); // authored cascade write.

    const boardSyncEntries = await syncEntriesFor('boards', BOARD);
    expect(boardSyncEntries.length).toBeGreaterThan(0);
  });

  it('applying a remote LIVE row with a changed position recomputes completedLineIds (positional staleness)', async () => {
    await seedWindowedCompleteTask(TASK_A);
    await seedWindowedCompleteTask(TASK_B);
    await seedWindowedCompleteTask(TASK_C);
    await db.boards.add(seedBoard(BOARD, { completedTasks: 3, version: 1 }));

    // Row 0 is NOT yet a line: A and B sit on row 0, C sits off-row at (1,0).
    await db.boardTasks.add(seedBoardTask(BT_A, BOARD, TASK_A, 0, 0));
    await db.boardTasks.add(seedBoardTask(BT_B, BOARD, TASK_B, 0, 1));
    const localC = seedBoardTask(BT_C, BOARD, TASK_C, 1, 0);
    await db.boardTasks.add(localC);

    let board = await db.boards.get(BOARD);
    expect(board?.completedLineIds ?? []).not.toContain('row_0');

    // A remote rearrange moves C onto (0,2) — completing row 0.
    const remoteMoved: BoardTask = {
      ...localC,
      row: 0,
      col: 2,
      version: 2,
      updatedAt: '2026-07-01T13:00:00.000Z',
    };

    const status = await applyRemoteSubdoc('boardTasks', remoteMoved, USER);
    expect(status).toMatch(/^Pulled /);

    board = await db.boards.get(BOARD);
    expect(board?.completedLineIds ?? []).toContain('row_0');
  });

  it('a pulled boardTasks row for a SEALED board does not live-cascade but DOES re-derive the sealed snapshot', async () => {
    const SEALED_AT = '2026-07-02T06:00:00.000Z';
    await seedWindowedCompleteTask(TASK_A);
    const sealedBoard = seedBoard(BOARD, {
      sealedAt: SEALED_AT,
      sealedCompletedCells: [],
      completedTasks: 0,
      version: 1,
    });
    await db.boards.add(sealedBoard);
    const localBt = seedBoardTask(BT_A, BOARD, TASK_A, 0, 0);
    await db.boardTasks.add(localBt);

    const remoteLive: BoardTask = {
      ...localBt,
      version: 2,
      updatedAt: '2026-07-01T13:00:00.000Z',
    };

    await applyRemoteSubdoc('boardTasks', remoteLive, USER);

    const board = await db.boards.get(BOARD);
    // Live cascade never mutates a sealed board's version...
    expect(board?.version).toBe(1);
    // ...but the deterministic sealed re-derive DOES update the frozen
    // snapshot from the local converged union (task is complete → cell 0 green).
    expect(board?.sealedCompletedCells).toEqual([0]);
    expect(board?.completedTasks).toBe(1);
  });
});

describe('migrationV17 — BoardTask isDeleted backfill', () => {
  it('backfills isDeleted: false on a legacy row missing the field', async () => {
    const legacyRow = {
      id: BT_A,
      boardId: BOARD,
      taskId: TASK_A,
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: START,
      updatedAt: START,
      version: 1,
      // isDeleted intentionally absent — simulates a pre-v17 row.
    };
    await db.boardTasks.add(legacyRow as unknown as BoardTask);

    await runMigrationV17({} as never);

    const row = await db.boardTasks.get(BT_A);
    expect(row?.isDeleted).toBe(false);
  });

  it('is idempotent — a row that already has isDeleted set is left untouched', async () => {
    const alreadyTombstoned = seedBoardTask(BT_A, BOARD, TASK_A, 0, 0, {
      isDeleted: true,
      deletedAt: START,
      version: 5,
    });
    await db.boardTasks.add(alreadyTombstoned);

    await runMigrationV17({} as never);

    const row = await db.boardTasks.get(BT_A);
    expect(row?.isDeleted).toBe(true); // untouched, not flipped to false
    expect(row?.version).toBe(5); // no spurious write
  });
});
