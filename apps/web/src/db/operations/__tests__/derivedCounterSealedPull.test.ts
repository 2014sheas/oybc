import { afterEach, describe, expect, it } from 'vitest';
import {
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
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch } from '../taskEventPull';

/**
 * Derived-counter freeze, Task 3 item 1 — the audit's failure scenario end to
 * end through the PULL path (audit 2026-09-23 finding #1).
 *
 * A sealed weekly board places a window-stamped derived counter whose local
 * latch says complete (a pre-freeze client propagated a later window's logs
 * into it). The device then pulls (1) the sealed board doc and (2) a ROOT
 * increment that occurred AFTER `sealedAt`. Both pull hooks re-derive the
 * sealed snapshot (`reDeriveSealedBoardsByIds` on the board branch,
 * `reDeriveSealedBoardsForTasks` on the event batch, which expands the root
 * to its window-stamped rows). The snapshot must stay what the in-window root
 * events say — byte-stable across the post-seal event — while a LATE
 * in-window event (pre-seal) still converges it.
 */

const USER = 'user-1';
const T = '2026-09-01T00:00:00.000Z';
const WS = '2026-09-14T00:00:00.000Z';
const WE = '2026-09-20T23:59:59.999Z';
const SEALED_AT = '2026-09-22T19:00:00.000Z';

const ROOT = '30000000-0000-4000-8000-000000000001';
const DERIVED = '30000000-0000-4000-8000-000000000002';
const BOARD = '30000000-0000-4000-8000-000000000003';

function task(over: Partial<Task>): Task {
  return {
    id: ROOT,
    userId: USER,
    title: 'Read',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T,
    updatedAt: T,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function inc(n: number, delta: number, occurredAt: string): TaskEvent {
  return {
    id: `30000000-0000-4000-8000-0000000001${String(n).padStart(2, '0')}`,
    userId: USER,
    taskId: ROOT,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

/** The sealed weekly as the sealing device pushed it (nothing complete). */
function sealedBoardDoc(): Board {
  return {
    id: BOARD,
    userId: USER,
    name: 'Last week',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: WS,
    endDate: WE,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    sealedAt: SEALED_AT,
    sealedCompletedCells: [],
    createdAt: T,
    updatedAt: SEALED_AT,
    version: 3,
    isDeleted: false,
  };
}

async function seedLocal(): Promise<void> {
  await db.tasks.add(task({ maxCount: 80, currentCount: 22 }));
  // Stale latch: true, as a pre-freeze client propagated later logs into it.
  await db.tasks.add(
    task({
      id: DERIVED,
      title: 'Read 3 pages',
      maxCount: 3,
      sharedCounterId: ROOT,
      baseline: 0,
      currentCount: 22,
      isCompleted: true,
      startDate: WS,
      endDate: WE,
      createdInWizard: true,
      timeframe: Timeframe.WEEKLY,
    }),
  );
  const bt: BoardTask = {
    id: '30000000-0000-4000-8000-000000000004',
    boardId: BOARD,
    taskId: DERIVED,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: T,
    updatedAt: T,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
  // In-window: +2 (< 3). Post-window, pre-seal overtime: +20 (outside the row's window).
  await db.taskEvents.bulkAdd([inc(1, 2, '2026-09-16T18:00:00.000Z'), inc(2, 20, '2026-09-21T09:00:00.000Z')]);
}

afterEach(async () => {
  await Promise.all([
    db.boards.clear(),
    db.boardTasks.clear(),
    db.tasks.clear(),
    db.compoundChildren.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('sealed board + window-stamped derived row through the pull path', () => {
  it('a post-seal ROOT increment leaves the sealed snapshot byte-stable; a late in-window one converges it', async () => {
    await seedLocal();

    // (1) Pull the sealed board doc → board-branch re-derive from the local union.
    expect(await applyRemoteSubdoc('boards', sealedBoardDoc(), USER)).toMatch(/^Pulled boards\//);
    const afterBoardPull = (await db.boards.get(BOARD))!;
    // The stale latch is NOT read: in-window 2 < 3 → still nothing complete.
    expect(afterBoardPull.sealedCompletedCells ?? []).toEqual([]);
    expect(afterBoardPull.completedTasks).toBe(0);

    // (2) Pull a ROOT increment that occurred AFTER sealedAt.
    const postSeal = await applyTaskEventsBatch(USER, [inc(3, 5, '2026-09-23T12:00:00.000Z')]);
    expect(postSeal.pulled).toBe(1);
    // Byte-stable: the sealed record is exactly what the board pull left.
    expect(await db.boards.get(BOARD)).toEqual(afterBoardPull);
    expect((await db.syncQueue.toArray()).filter((q) => q.entityType === 'boards')).toEqual([]);

    // (3) Control — a LATE in-window event (pre-seal, pulled after) does
    //     converge the sealed snapshot: 2 + 1 = 3 >= 3.
    const lateInWindow = await applyTaskEventsBatch(USER, [inc(4, 1, '2026-09-19T08:00:00.000Z')]);
    expect(lateInWindow.pulled).toBe(1);
    const converged = (await db.boards.get(BOARD))!;
    expect(converged.sealedCompletedCells).toEqual([0]);
    expect(converged.completedTasks).toBe(1);
  });
});

describe('sealed board + INDEFINITE window-stamped derived row through the pull path', () => {
  /**
   * The row has no `endDate` (window `[startDate, ∞)`), so its own window
   * never excludes a later root event — `sealedAt` is the ONLY bound between
   * the post-seal increment and the sealed snapshot. The test above is
   * satisfied by the row's `endDate` alone; this one pins the seal bound.
   */
  it('a post-seal ROOT increment leaves the sealed snapshot byte-stable when sealedAt is the binding bound', async () => {
    await db.tasks.add(task({ maxCount: 80, currentCount: 2 }));
    await db.tasks.add(
      task({
        id: DERIVED,
        title: 'Read 3 pages',
        maxCount: 3,
        sharedCounterId: ROOT,
        baseline: 0,
        currentCount: 2,
        isCompleted: false,
        startDate: WS,
        // no endDate: window [startDate, ∞)
        createdInWizard: true,
        timeframe: Timeframe.WEEKLY,
      }),
    );
    await db.boardTasks.add({
      id: '30000000-0000-4000-8000-000000000004',
      boardId: BOARD,
      taskId: DERIVED,
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: T,
      updatedAt: T,
      version: 1,
      isDeleted: false,
    });
    // Pre-seal, in the row's window: +2 (< 3).
    await db.taskEvents.add(inc(1, 2, '2026-09-16T18:00:00.000Z'));

    expect(await applyRemoteSubdoc('boards', sealedBoardDoc(), USER)).toMatch(/^Pulled boards\//);
    const afterBoardPull = (await db.boards.get(BOARD))!;
    expect(afterBoardPull.sealedCompletedCells ?? []).toEqual([]);
    expect(afterBoardPull.completedTasks).toBe(0);

    // +5 after sealedAt: inside the row's unbounded window, outside the seal.
    // Unbounded, 2 + 5 = 7 >= 3 would turn cell 0 green.
    const postSeal = await applyTaskEventsBatch(USER, [inc(3, 5, '2026-09-23T12:00:00.000Z')]);
    expect(postSeal.pulled).toBe(1);
    expect(await db.boards.get(BOARD)).toEqual(afterBoardPull);
    expect((await db.syncQueue.toArray()).filter((q) => q.entityType === 'boards')).toEqual([]);
  });
});
