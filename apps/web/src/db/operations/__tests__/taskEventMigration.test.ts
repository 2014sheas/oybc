import { afterEach, describe, expect, it } from 'vitest';
import type { Transaction } from 'dexie';
import { OperatorType, TaskType, backfillTaskEventId, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { runMigrationV13 } from '../migrationV13';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Migration & backfill,
 * step 2) — the v13 event backfill. Verifies event-owning tasks get a
 * deterministic backfill event and the carve-out tasks (derived / compound)
 * are skipped. `runMigrationV13` operates on the raw Dexie singleton, so it can
 * be driven directly with a passthrough transaction handle.
 */

const NOW = '2026-02-01T00:00:00.000Z';

async function seedTask(overrides: Partial<Task> & Pick<Task, 'id' | 'type'>): Promise<Task> {
  const task: Task = {
    userId: 'user-1',
    title: 'T',
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as Task;
  await db.tasks.add(task);
  return task;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('migrationV13 — Windowed Completion event backfill', () => {
  it('backfills a completion event for a completed NORMAL task (deterministic id) + enqueues sync CREATE', async () => {
    await seedTask({
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      type: TaskType.NORMAL,
      isCompleted: true,
      completedAt: '2026-01-15T00:00:00.000Z',
    });

    await runMigrationV13({} as Transaction);

    const evId = backfillTaskEventId('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'completion');
    const ev = await db.taskEvents.get(evId);
    expect(ev).toBeTruthy();
    expect(ev?.kind).toBe('completion');
    expect(ev?.occurredAt).toBe('2026-01-15T00:00:00.000Z');

    const q = await db.syncQueue.toArray();
    expect(q.some((r) => r.entityType === 'taskEvents' && r.entityId === evId)).toBe(true);
  });

  it('backfills an increment event (delta = currentCount) for a plain COUNTING task', async () => {
    await seedTask({
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      type: TaskType.COUNTING,
      maxCount: 10,
      currentCount: 4,
    });

    await runMigrationV13({} as Transaction);

    const evId = backfillTaskEventId('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'increment');
    const ev = await db.taskEvents.get(evId);
    expect(ev?.kind).toBe('increment');
    expect(ev?.delta).toBe(4);
  });

  it('skips a NORMAL task that was never completed, and a COUNTING task at 0', async () => {
    await seedTask({ id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', type: TaskType.NORMAL, isCompleted: false });
    await seedTask({ id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', type: TaskType.COUNTING, maxCount: 5, currentCount: 0 });

    await runMigrationV13({} as Transaction);

    expect(await db.taskEvents.count()).toBe(0);
  });

  it('skips carve-out tasks: derived counters, compounds, and deleted tasks', async () => {
    // Derived counter (sharedCounterId set) — mirrors the source; minting an
    // event would double-count.
    await seedTask({
      id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      type: TaskType.COUNTING,
      maxCount: 5,
      currentCount: 3,
      sharedCounterId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      baseline: 0,
    });
    // Compound — completion is derived from children, never event-owning.
    await seedTask({
      id: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: true,
      completedAt: NOW,
    });
    // Deleted event-owning task — skipped.
    await seedTask({
      id: '11111111-1111-4111-8111-111111111111',
      type: TaskType.NORMAL,
      isCompleted: true,
      completedAt: NOW,
      isDeleted: true,
    });

    await runMigrationV13({} as Transaction);

    expect(await db.taskEvents.count()).toBe(0);
  });

  it('is idempotent — a second run does not duplicate the deterministic backfill row', async () => {
    await seedTask({
      id: '22222222-2222-4222-8222-222222222222',
      type: TaskType.NORMAL,
      isCompleted: true,
      completedAt: NOW,
    });

    await runMigrationV13({} as Transaction);
    await runMigrationV13({} as Transaction);

    expect(await db.taskEvents.count()).toBe(1);
  });
});
