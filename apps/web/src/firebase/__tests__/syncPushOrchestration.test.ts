import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SyncOperationType, SyncStatus, type SyncableEntity } from '@oybc/shared';
import type { SyncDocStore } from '../syncService';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a signed-in user. The injected doc store below
// means the real Firestore handle is never used.
vi.mock('../config', () => ({ auth: { currentUser: { uid: 'me' } }, firestore: {} }));

// The queue-maintenance reads (`where('status')` — a Dexie virtual index over
// `[status+priority+createdAt]`) throw a DataError under fake-indexeddb; they
// are orthogonal to the per-item orchestration pinned here (the stale-reset
// read is already try/caught in `pushSync`), so stub the two uncaught-or-noisy
// ones. `fetchPendingSyncItems` (a real compound-index range) runs for real.
vi.mock('../../db/operations/syncQueue', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../db/operations/syncQueue')>()),
  promoteEligibleFailedItems: vi.fn(async () => 0),
  countExhaustedSyncItems: vi.fn(async () => 0),
}));

const { pushSync } = await import('../syncService');
const { db } = await import('../../db/internal');
const { addToSyncQueue } = await import('../../db/operations/syncQueue');

const USER = 'me';
const TASK_ID = 'task-1';
const PATH = `users/${USER}/tasks/${TASK_ID}`;

/** In-memory `SyncDocStore`: a path → doc map plus a log of every write. */
function makeFakeStore(docs: Record<string, SyncableEntity> = {}) {
  const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
  let failWith: Error | null = null;
  const store: SyncDocStore = {
    async getDoc(path) {
      return docs[path] ?? null;
    },
    async setDoc(path, data) {
      if (failWith) throw failWith;
      writes.push({ path, data });
    },
  };
  return { store, writes, failNextWrites: (err: Error) => (failWith = err) };
}

/** A minimal task-shaped syncable row; only the LWW fields matter to push. */
function task(version: number, updatedAt: string, title: string): SyncableEntity {
  return { id: TASK_ID, userId: USER, title, version, updatedAt, isDeleted: false };
}

async function enqueueLocal(local: SyncableEntity): Promise<void> {
  await db.table('tasks').put(local);
  await addToSyncQueue('tasks', TASK_ID, SyncOperationType.UPDATE, local);
}

async function onlyQueueItem() {
  const items = await db.syncQueue.toArray();
  expect(items).toHaveLength(1);
  return items[0];
}

/**
 * Push orchestration (read remote → LWW → write → mark completed), driven
 * through the injectable `SyncDocStore` seam. iOS twin:
 * `SyncPushOrchestrationTests.swift`.
 */
describe('pushSync — LWW orchestration through the doc-store seam', () => {
  beforeEach(async () => {
    // The stale IN_PROGRESS reset read hits the same fake-indexeddb DataError
    // and is caught + logged by `pushSync`; keep the log quiet.
    vi.spyOn(console, 'error').mockImplementation(() => {});
    await db.syncQueue.clear();
    await db.table('tasks').clear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('local wins (local version > remote): writes the local payload and completes the item', async () => {
    const local = task(3, '2026-09-24T10:00:00.000Z', 'local title');
    const { store, writes } = makeFakeStore({ [PATH]: task(2, '2026-09-24T12:00:00.000Z', 'remote') });
    await enqueueLocal(local);

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 1, conflicts: 0, failed: 0 });
    expect(writes).toHaveLength(1);
    expect(writes[0].path).toBe(PATH);
    expect(writes[0].data).toMatchObject({ title: 'local title', version: 3 });
    expect(writes[0].data).toHaveProperty('_syncedAt'); // wire shaping ran
    expect((await onlyQueueItem()).status).toBe(SyncStatus.COMPLETED);
  });

  it('remote wins (remote version > local): no remote write; remote overwrites the local row; item completed, not re-enqueued', async () => {
    // Push-path remote-wins = `table.put(remoteData)` (syncService.ts). The
    // BOARD_INTEGRITY PR-4 re-enqueue is PULL-path local-wins only — the push
    // path must not enqueue a fresh item here.
    const remote = task(5, '2026-09-24T09:00:00.000Z', 'remote title');
    const { store, writes } = makeFakeStore({ [PATH]: remote });
    await enqueueLocal(task(4, '2026-09-24T11:00:00.000Z', 'local title'));

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 0, conflicts: 1, failed: 0 });
    expect(writes).toHaveLength(0);
    expect(await db.table('tasks').get(TASK_ID)).toEqual(remote);
    expect((await onlyQueueItem()).status).toBe(SyncStatus.COMPLETED);
  });

  it('equal version, older local updatedAt: remote wins the tie-break (no write, local overwritten)', async () => {
    const remote = task(2, '2026-09-24T12:00:00.000Z', 'remote title');
    const { store, writes } = makeFakeStore({ [PATH]: remote });
    await enqueueLocal(task(2, '2026-09-24T11:59:59.000Z', 'local title'));

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 0, conflicts: 1, failed: 0 });
    expect(writes).toHaveLength(0);
    expect(await db.table('tasks').get(TASK_ID)).toEqual(remote);
    expect((await onlyQueueItem()).status).toBe(SyncStatus.COMPLETED);
  });

  it('write failure: item goes FAILED with retryCount + 1 and the error recorded; local row untouched', async () => {
    const local = task(3, '2026-09-24T10:00:00.000Z', 'local title');
    const { store, writes, failNextWrites } = makeFakeStore({ [PATH]: task(1, '2026-09-24T09:00:00.000Z', 'r') });
    failNextWrites(new Error('unavailable: offline'));
    await enqueueLocal(local);

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 0, conflicts: 0, failed: 1 });
    expect(writes).toHaveLength(0);
    const item = await onlyQueueItem();
    expect(item.status).toBe(SyncStatus.FAILED);
    expect(item.retryCount).toBe(1);
    expect(item.lastError).toBe('unavailable: offline');
    expect(await db.table('tasks').get(TASK_ID)).toEqual(local);
  });
});
