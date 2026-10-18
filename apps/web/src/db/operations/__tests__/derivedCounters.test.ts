import { afterEach, describe, expect, it } from 'vitest';
import {
  TaskType,
  derivedTaskId,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { refreshDerivedBaselines } from '../derivedCounters';

/**
 * Board Sources §Member rules B2 (web) — the non-authored baseline refresh of
 * legacy window-stamped derived rows. (The mint — RB2/RB3/RB10 — retired in
 * TASK_WINDOW_REWORK slice 3b: the planner emits placement parameters, pinned
 * by the shared vectors and `wizardBoard.test.ts` / `recurringBoardSpawnMix.test.ts`.)
 */

const USER = 'user-1';
const BOARD = 'b0000000-0000-4000-8000-000000000001';
/** Local-ISO, exactly like a real `Board.startDate` (no trailing Z). */
const WINDOW_START = '2026-09-14T00:00:00.000';
const BEFORE_A = '2026-09-01T09:00:00.000Z';
const BEFORE_B = '2026-09-10T09:00:00.000Z';

const ROOT = 'a0000000-0000-4000-8000-000000000001';

afterEach(async () => {
  await db.tasks.clear();
  await db.taskEvents.clear();
  await db.compoundChildren.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

function countingTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Run 35 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 35,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: BEFORE_A,
    updatedAt: BEFORE_A,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function incrementEvent(id: string, taskId: string, delta: number, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

describe('refreshDerivedBaselines — non-authored', () => {
  const DERIVED = derivedTaskId(BOARD, ROOT);

  async function seedDerived(baseline: number): Promise<void> {
    await db.tasks.add(countingTask(ROOT, { currentCount: 20 }));
    await db.tasks.add(
      countingTask(DERIVED, {
        sharedCounterId: ROOT,
        baseline,
        createdInWizard: true,
        startDate: WINDOW_START,
        version: 1,
      }),
    );
  }

  it('rewrites only `baseline` — version untouched, nothing enqueued — and no-ops when unchanged', async () => {
    await seedDerived(2);
    await db.taskEvents.add(incrementEvent('ev-1', ROOT, 2, BEFORE_A));

    const unchanged = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(unchanged).toBe(0);

    // A backdated (pre-window) increment lands — e.g. pulled from another
    // device — so the window baseline must move.
    await db.taskEvents.add(incrementEvent('ev-2', ROOT, 5, BEFORE_B));
    const before = await db.tasks.get(DERIVED);
    const touched = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );

    expect(touched).toBe(1);
    const after = await db.tasks.get(DERIVED);
    expect(after?.baseline).toBe(7);
    expect(after?.version).toBe(before?.version);
    expect(after?.updatedAt).toBe(before?.updatedAt);
    expect(await db.syncQueue.count()).toBe(0);

    const again = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(again).toBe(0);
  });

  it('ignores a hand-made linked counter (no wizard provenance / no window stamp)', async () => {
    await db.tasks.add(countingTask(ROOT, { currentCount: 20 }));
    await db.tasks.add(
      countingTask('a0000000-0000-4000-8000-000000000009', {
        sharedCounterId: ROOT,
        baseline: 0,
        // no `createdInWizard`, no `startDate` — ordinary user data.
      }),
    );
    await db.taskEvents.add(incrementEvent('ev-1', ROOT, 9, BEFORE_A));

    const touched = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(touched).toBe(0);
    const linked = await db.tasks.get('a0000000-0000-4000-8000-000000000009');
    expect(linked?.baseline).toBe(0);
  });
});
