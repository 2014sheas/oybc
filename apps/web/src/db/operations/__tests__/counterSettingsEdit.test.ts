import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { TaskType, type SyncableEntity, type Task } from '@oybc/shared';

// `firebase/config` initializes Firebase at import time — stub it (the
// injected doc store means real Firestore is never used).
vi.mock('../../../firebase/config', () => ({ auth: { currentUser: { uid: 'me' } }, firestore: {} }));

const { db } = await import('../../internal');
const { saveTaskEdit } = await import('../compoundStructureEdit');
const { pushSync } = await import('../../../firebase/syncService');

/**
 * Shared counter settings PR 1 (docs/SHARED_COUNTER_SETTINGS.md §1) — the DB
 * twin of iOS `CounterSettingsEditTests`: `saveTaskEdit` (+ its
 * `counterSettingsEdit` propagation keys) sets the four root fields, a
 * key-present-`undefined` clears them (Dexie key deleted → `deleteField()`
 * on push via the clearable path), and a template edit re-renders an
 * auto-titled copy through the DB while keeping a custom one.
 */

const T0 = '2026-10-01T00:00:00.000Z';
const USER = 'me';
const SETTINGS = ['counterName', 'titleTemplateSingular', 'titleTemplatePlural', 'timeframeGoals'] as const;

const task = (over: Partial<Task>): Task =>
  ({
    id: 'root', userId: USER, title: 'Run miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    isCounter: true, countKind: 'discrete', currentCount: 0, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

const copy = (id: string, title: string, maxCount = 10): Task =>
  task({ id, title, maxCount, isCounter: false, sharedCounterId: 'root' });

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(),
    db.compoundChildren.clear(), db.syncQueue.clear(),
  ]);
});

describe('saveTaskEdit — shared counter settings (DB level)', () => {
  it('sets the four fields; a template edit re-renders the auto copy, keeps the custom one', async () => {
    await db.tasks.bulkAdd([task({}), copy('auto', 'Run 10 miles'), copy('custom', 'Morning run')]);

    await saveTaskEdit('root', {
      title: 'Running',
      counterName: 'Running',
      titleTemplateSingular: 'Jog #N mile',
      titleTemplatePlural: 'Jog #N miles',
      timeframeGoals: { weekly: 20, yearly: 1000 },
    });

    expect(await db.tasks.get('root')).toMatchObject({
      title: 'Running',
      counterName: 'Running',
      titleTemplateSingular: 'Jog #N mile',
      titleTemplatePlural: 'Jog #N miles',
      timeframeGoals: { weekly: 20, yearly: 1000 },
    });
    expect((await db.tasks.get('auto'))!.title).toBe('Jog 10 miles');
    expect((await db.tasks.get('custom'))!.title).toBe('Morning run');
  });

  it('a key-present-undefined clear deletes the Dexie keys and pushes deleteField() for each', async () => {
    await db.tasks.bulkAdd([
      task({
        title: 'Running', counterName: 'Running', titleTemplateSingular: 'Jog #N mile',
        titleTemplatePlural: 'Jog #N miles', timeframeGoals: { weekly: 20 },
      }),
      copy('auto', 'Jog 10 miles'),
    ]);

    await saveTaskEdit('root', {
      title: 'Run miles',
      counterName: undefined,
      titleTemplateSingular: undefined,
      titleTemplatePlural: undefined,
      timeframeGoals: undefined,
    });

    const cleared = (await db.tasks.get('root'))!;
    for (const k of SETTINGS) expect(k in cleared).toBe(false);
    expect((await db.tasks.get('auto'))!.title).toBe('Run 10 miles');

    const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
    const store = {
      async getDoc(): Promise<SyncableEntity | null> {
        return null;
      },
      async setDoc(path: string, data: Record<string, unknown>) {
        writes.push({ path, data });
      },
    };
    await pushSync(USER, { store });
    const rootWrite = writes.find((w) => w.path === `users/${USER}/tasks/root`);
    expect(rootWrite).toBeDefined();
    // The keys are present (deleteField() sentinels), not merely omitted.
    for (const k of SETTINGS) {
      expect(Object.keys(rootWrite!.data)).toContain(k);
      expect(rootWrite!.data[k]).not.toBeUndefined();
      expect(typeof rootWrite!.data[k]).toBe('object');
    }
    expect(rootWrite!.data.title).toBe('Run miles');
  });
});
