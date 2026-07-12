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
import { applyTaskEventsBatch } from '../../../firebase/syncService';

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
