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
import { applyTaskEventsBatch, healMissingCompletionEvents } from '../taskEventPull';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Sync + §Testing matrix web
 * row) — the BATCHED pull-path recompute: apply all pulled event rows, then
 * recompute each affected event-owning task's caches ONCE and run one
 * derivation pass per affected board. Plus the events-before-task ordering skip
 * and the derived-task carve-out (C1 regression).
 */

const USER = 'user-1';
const START = '2026-05-01T00:00:00.000Z';
const OCCUR = '2026-06-01T00:00:00.000Z';

const TASK_A = '10000000-0000-4000-8000-000000000001';
const TASK_B = '10000000-0000-4000-8000-000000000002';
const DERIVED = '10000000-0000-4000-8000-000000000003';
const SOURCE = '10000000-0000-4000-8000-000000000004';

function completionEvent(id: string, taskId: string, over: Partial<TaskEvent> = {}): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt: OCCUR,
    createdAt: OCCUR,
    updatedAt: OCCUR,
    version: 1,
    isDeleted: false,
    ...over,
  };
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
    version: 5,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedBoardWithTasks(boardId: string, taskIds: string[]): Promise<void> {
  const board: Board = {
    id: boardId,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
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
  };
  await db.boards.add(board);
  let cell = 0;
  for (const taskId of taskIds) {
    const bt: BoardTask = {
      id: `bt-${taskId}`,
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
    cell += 1;
  }
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('applyTaskEventsBatch — batched pull recompute', () => {
  it('recomputes each affected task once and cascades affected boards (one board update for two tasks)', async () => {
    await seedNormalTask(TASK_A);
    await seedNormalTask(TASK_B);
    await seedBoardWithTasks('20000000-0000-4000-8000-000000000001', [TASK_A, TASK_B]);

    const res = await applyTaskEventsBatch(USER, [
      completionEvent('30000000-0000-4000-8000-000000000001', TASK_A),
      completionEvent('30000000-0000-4000-8000-000000000002', TASK_B),
    ]);
    expect(res.pulled).toBe(2);

    // Both tasks' caches recomputed from events (no version bump — pull path).
    const a = await db.tasks.get(TASK_A);
    const b = await db.tasks.get(TASK_B);
    expect(a?.isCompleted).toBe(true);
    expect(b?.isCompleted).toBe(true);
    expect(a?.version).toBe(5); // recompute is NOT an authored write

    // Board recomputed once, reflecting both squares (+ derivation).
    const board = await db.boards.get('20000000-0000-4000-8000-000000000001');
    expect(board?.completedTasks).toBe(2);
  });

  it('applies an event whose task is not local yet but SKIPS the recompute (events-before-task ordering)', async () => {
    // No local task for TASK_A.
    const res = await applyTaskEventsBatch(USER, [
      completionEvent('30000000-0000-4000-8000-000000000003', TASK_A),
    ]);
    // Row is upserted (pulled) — the safety-net picks up the recompute later.
    expect(res.pulled).toBe(1);
    expect(await db.taskEvents.get('30000000-0000-4000-8000-000000000003')).toBeTruthy();
    // No task row was created / recomputed.
    expect(await db.tasks.get(TASK_A)).toBeUndefined();
  });

  it('LWW-applies a tombstone (undo) and recomputes the cache to incomplete', async () => {
    await seedNormalTask(TASK_A);
    // Local live event (already completed).
    await db.taskEvents.add(completionEvent('30000000-0000-4000-8000-000000000004', TASK_A));
    await db.tasks.update(TASK_A, { isCompleted: true, completedAt: OCCUR });

    // Remote tombstone (higher version) arrives.
    const res = await applyTaskEventsBatch(USER, [
      completionEvent('30000000-0000-4000-8000-000000000004', TASK_A, {
        isDeleted: true,
        deletedAt: OCCUR,
        version: 2,
      }),
    ]);
    expect(res.pulled).toBe(1);
    expect((await db.taskEvents.get('30000000-0000-4000-8000-000000000004'))?.isDeleted).toBe(true);
    expect((await db.tasks.get(TASK_A))?.isCompleted).toBe(false);
  });

  it('carve-out (C1): a derived counter pulled event leaves its propagation-stamped caches + latch intact', async () => {
    // Derived task: sharedCounterId set, isCompleted latched true, currentCount mirrored.
    const derived: Task = {
      id: DERIVED,
      userId: USER,
      title: 'D',
      type: TaskType.COUNTING,
      maxCount: 5,
      currentCount: 7,
      isCompleted: true,
      completedAt: OCCUR,
      sharedCounterId: SOURCE,
      baseline: 0,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 9,
      isDeleted: false,
    };
    await db.tasks.add(derived);

    // An (illegitimate) event for the derived task must NOT recompute its caches.
    await applyTaskEventsBatch(USER, [
      { ...completionEvent('30000000-0000-4000-8000-000000000005', DERIVED), kind: 'increment', delta: 1 },
    ]);

    const after = await db.tasks.get(DERIVED);
    expect(after?.isCompleted).toBe(true); // latch intact
    expect(after?.currentCount).toBe(7); // propagation-stamped value intact
    expect(after?.version).toBe(9);
  });

  it('rejects a userId-mismatched event row', async () => {
    const res = await applyTaskEventsBatch(USER, [
      completionEvent('30000000-0000-4000-8000-000000000006', TASK_A, { userId: 'someone-else' }),
    ]);
    expect(res.pulled).toBe(0);
    expect(res.details[0]).toContain('userId mismatch');
  });
});

/**
 * Board Sources §Member rules (B2) — a pulled (or healed) event that predates
 * a board's window changes that window's `baseline`, so both pull paths
 * refresh every window-stamped derived counter on the affected root. The
 * refresh is NON-AUTHORED: `baseline` only, no version bump, no enqueue.
 */
describe('pull paths — window-stamped derived baseline refresh', () => {
  const ROOT = '40000000-0000-4000-8000-000000000001';
  const WINDOW_START = '2026-06-01T00:00:00.000';
  const BACKDATED = '2026-05-15T00:00:00.000Z';

  async function seedRootAndDerived(over: Partial<Task> = {}): Promise<string> {
    const root: Task = {
      id: ROOT,
      userId: USER,
      title: 'Run 20 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 20,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 3,
      isDeleted: false,
      ...over,
    } as Task;
    await db.tasks.add(root);
    const derivedId = '40000000-0000-4000-8000-000000000002';
    await db.tasks.add({
      id: derivedId,
      userId: USER,
      title: 'Run 5 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 5,
      sharedCounterId: ROOT,
      baseline: 0,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      timeframe: Timeframe.DAILY,
      startDate: WINDOW_START,
      createdAt: START,
      updatedAt: START,
      version: 4,
      isDeleted: false,
    } as Task);
    return derivedId;
  }

  it('a pulled in-window ROOT event re-derives the LIVE board that places only the derived row', async () => {
    // The root is never placed; the derived row resolves from the root's events
    // (derivation kernel, 2026-09-23 amendment). The live cascade must reach
    // the board through the derived row, or its stored stats stay stale.
    const derivedId = await seedRootAndDerived();
    const BOARD = '40000000-0000-4000-8000-0000000000b1';
    await seedBoardWithTasks(BOARD, [derivedId]);

    const res = await applyTaskEventsBatch(USER, [
      {
        id: '40000000-0000-4000-8000-0000000000e1',
        userId: USER,
        taskId: ROOT,
        kind: 'increment',
        delta: 5,
        occurredAt: '2026-06-10T12:00:00.000Z', // inside the derived row's window
        createdAt: '2026-06-10T12:00:00.000Z',
        updatedAt: '2026-06-10T12:00:00.000Z',
        version: 1,
        isDeleted: false,
      },
    ]);
    expect(res.pulled).toBe(1);

    const board = await db.boards.get(BOARD);
    expect(board?.completedTasks).toBe(1);
    expect(board?.version).toBe(2);
  });

  it('a batch carrying a backdated increment moves the derived baseline without authoring a write', async () => {
    const derivedId = await seedRootAndDerived();
    const before = await db.tasks.get(derivedId);

    const res = await applyTaskEventsBatch(USER, [
      {
        id: '40000000-0000-4000-8000-000000000003',
        userId: USER,
        taskId: ROOT,
        kind: 'increment',
        delta: 6,
        occurredAt: BACKDATED, // before the derived row's window opened
        createdAt: BACKDATED,
        updatedAt: BACKDATED,
        version: 1,
        isDeleted: false,
      },
    ]);
    expect(res.pulled).toBe(1);

    const after = await db.tasks.get(derivedId);
    expect(after?.baseline).toBe(6);
    expect(after?.version).toBe(before?.version);
    expect(after?.updatedAt).toBe(before?.updatedAt);
    expect((await db.syncQueue.toArray()).filter((q) => q.entityId === derivedId)).toHaveLength(
      0,
    );
  });

  it('an in-window increment leaves the baseline alone (it is this window’s progress)', async () => {
    const derivedId = await seedRootAndDerived();
    // A real pre-window history, so the assertion below is "3, not 9" rather
    // than "0 stayed 0".
    await db.taskEvents.add({
      id: '40000000-0000-4000-8000-000000000005',
      userId: USER,
      taskId: ROOT,
      kind: 'increment',
      delta: 3,
      occurredAt: BACKDATED,
      createdAt: BACKDATED,
      updatedAt: BACKDATED,
      version: 1,
      isDeleted: false,
    });
    await db.tasks.update(derivedId, { baseline: 3 });

    await applyTaskEventsBatch(USER, [
      {
        id: '40000000-0000-4000-8000-000000000004',
        userId: USER,
        taskId: ROOT,
        kind: 'increment',
        delta: 6,
        occurredAt: '2026-06-02T00:00:00.000Z',
        createdAt: '2026-06-02T00:00:00.000Z',
        updatedAt: '2026-06-02T00:00:00.000Z',
        version: 1,
        isDeleted: false,
      },
    ]);

    expect((await db.tasks.get(derivedId))?.baseline).toBe(3);
  });

  it('healMissingCompletionEvents refreshes the baseline from the event it mints', async () => {
    // A lifetime-complete root with NO events — the exact fresh-install gap
    // the heal sweep closes. Its backfill event is anchored at `updatedAt`,
    // which predates the derived row's window.
    const derivedId = await seedRootAndDerived({
      currentCount: 4,
      updatedAt: BACKDATED,
    });
    const before = await db.tasks.get(derivedId);

    const minted = await healMissingCompletionEvents(USER);
    expect(minted).toBe(1);

    const after = await db.tasks.get(derivedId);
    expect(after?.baseline).toBe(4);
    expect(after?.version).toBe(before?.version);
    expect((await db.syncQueue.toArray()).filter((q) => q.entityId === derivedId)).toHaveLength(
      0,
    );
  });
});
