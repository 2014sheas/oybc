import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import {
  incrementSharedCounter,
  decrementSharedCounter,
  undoLastCounterLog,
} from '../tasks.sharedCounter';
import { insertIncrementEventRaw } from '../taskEvents';
import { SEED_EVENT_OCCURRED_AT, TaskType, type Task } from '@oybc/shared';

const NOW = '2026-07-16T10:00:00.000Z';
function goallessSource(id = 'src1'): Task {
  return {
    id, userId: 'u1', title: 'Push-ups (reps)', type: TaskType.COUNTING,
    action: 'Push-ups', unit: 'reps', isCounter: true,
    currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
  } as unknown as Task;
}
afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(),
    db.boardTasks.clear(), db.compoundChildren.clear(), db.syncQueue.clear()]);
});

describe('goal-less counter engine (P5)', () => {
  it('increments a goal-less source without throwing; never auto-completes', async () => {
    await db.tasks.add(goallessSource());
    await incrementSharedCounter('src1', 5);
    const t = await db.tasks.get('src1');
    expect(t!.currentCount).toBe(5);
    expect(t!.isCompleted).toBe(false);
  });
  it('decrements a goal-less source without throwing', async () => {
    await db.tasks.add({ ...goallessSource(), currentCount: 3 });
    const r = await decrementSharedCounter('src1', 2);
    expect(r.effectiveDelta).toBe(2);
    expect((await db.tasks.get('src1'))!.currentCount).toBe(1);
  });
  it('goaled source latch still fires (regression)', async () => {
    await db.tasks.add({ ...goallessSource('src2'), isCounter: undefined, maxCount: 5 });
    await incrementSharedCounter('src2', 5);
    expect((await db.tasks.get('src2'))!.isCompleted).toBe(true);
  });
  it('insertIncrementEventRaw honors an occurredAt override (seed sentinel)', async () => {
    await db.tasks.add(goallessSource('src3'));
    await db.transaction('rw', [db.tasks, db.taskEvents, db.syncQueue], async () => {
      await insertIncrementEventRaw('src3', 500, undefined, NOW, SEED_EVENT_OCCURRED_AT);
    });
    const ev = await db.taskEvents.where('taskId').equals('src3').first();
    expect(ev!.occurredAt).toBe(SEED_EVENT_OCCURRED_AT);
    expect(ev!.createdAt).toBe(NOW);
  });
});

/**
 * Board Sources §Member rules (B2) — every local write to a shared-counter
 * root refreshes the `baseline` of the window-stamped derived counters hanging
 * off it, as a non-authored write. An ordinary increment lands inside the
 * window and must NOT move the baseline; an undo that reverses a PRE-window
 * entry must.
 */
describe('shared-counter ops — window-stamped derived baseline refresh', () => {
  const ROOT = 'root-1';
  const DERIVED = 'derived-1';
  const WINDOW_START = '2026-07-16T00:00:00.000';
  const PRE_WINDOW = '2026-07-10T09:00:00.000Z';

  async function seedRootWithPreWindowLog(): Promise<void> {
    await db.tasks.add({
      id: ROOT,
      userId: 'u1',
      title: 'Push-ups 100 reps',
      type: TaskType.COUNTING,
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 100,
      currentCount: 8,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await db.taskEvents.add({
      id: 'ev-pre',
      userId: 'u1',
      taskId: ROOT,
      kind: 'increment',
      delta: 8,
      occurredAt: PRE_WINDOW,
      createdAt: PRE_WINDOW,
      updatedAt: PRE_WINDOW,
      version: 1,
      isDeleted: false,
    });
    await db.tasks.add({
      id: DERIVED,
      userId: 'u1',
      title: 'Push-ups 20 reps',
      type: TaskType.COUNTING,
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 20,
      sharedCounterId: ROOT,
      baseline: 8,
      currentCount: 8,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: WINDOW_START,
      createdAt: NOW,
      updatedAt: NOW,
      version: 2,
      isDeleted: false,
    } as unknown as Task);
  }

  it('an increment mirrors the count but leaves the baseline at its pre-window value', async () => {
    await seedRootWithPreWindowLog();

    await incrementSharedCounter(ROOT, 4);

    const derived = await db.tasks.get(DERIVED);
    expect(derived!.currentCount).toBe(12); // lifetime mirror
    expect(derived!.baseline).toBe(8); // 12 − 8 = 4 this window
  });

  it('undoing a pre-window entry drops it out of the baseline', async () => {
    await seedRootWithPreWindowLog();
    // A second, in-window entry so the pre-window one is not the last — it is
    // undone in two steps, proving the refresh runs on every undo.
    await incrementSharedCounter(ROOT, 4);
    expect((await db.tasks.get(DERIVED))!.baseline).toBe(8);

    await undoLastCounterLog(ROOT); // reverses the in-window +4
    expect((await db.tasks.get(DERIVED))!.baseline).toBe(8);

    await undoLastCounterLog(ROOT); // reverses the PRE-window +8
    const derived = await db.tasks.get(DERIVED);
    expect(derived!.baseline).toBe(0);
    expect(derived!.currentCount).toBe(0);
  });

  it('a decrement of a pre-window-only log leaves the baseline alone (the event is in-window)', async () => {
    await seedRootWithPreWindowLog();

    await decrementSharedCounter(ROOT, 3);

    const derived = await db.tasks.get(DERIVED);
    expect(derived!.currentCount).toBe(5);
    // The −3 event occurred NOW, inside the window, so the baseline — the
    // lifetime total at the moment the window opened — is untouched.
    expect(derived!.baseline).toBe(8);
  });
});
