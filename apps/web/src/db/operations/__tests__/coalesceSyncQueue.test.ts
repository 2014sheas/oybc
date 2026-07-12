import { afterEach, describe, expect, it } from 'vitest';
import {
  SyncOperationType,
  SyncStatus,
  type SyncQueueItem,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  addToSyncQueue,
  coalesceSyncOperation,
} from '../syncQueue';

/**
 * Covers D3 (issue #296): per-entity coalescing in `addToSyncQueue`. N edits to
 * one entity used to enqueue N full-snapshot rows → N Firestore writes. Now a
 * burst collapses to ONE pending row carrying the LAST snapshot, with operation
 * type resolved per `coalesceSyncOperation`.
 *
 * Firebase-free: imports only the Dexie singleton (`db`) + `@oybc/shared`, so it
 * runs in the node Vitest harness against `fake-indexeddb`.
 */

afterEach(async () => {
  await db.syncQueue.clear();
});

async function pendingFor(
  entityType: string,
  entityId: string
): Promise<SyncQueueItem[]> {
  return (
    await db.syncQueue
      .where('[entityType+entityId]')
      .equals([entityType, entityId])
      .toArray()
  ).filter((r) => r.status === SyncStatus.PENDING);
}

describe('coalesceSyncOperation — pure precedence', () => {
  const { CREATE, UPDATE, DELETE } = SyncOperationType;
  // A standard (non-append-only) entity type for the generic precedence table.
  const E = 'tasks';

  it('create + update stays create (not yet on server)', () => {
    expect(coalesceSyncOperation(CREATE, UPDATE, true, E)).toEqual({
      kind: 'replace',
      operationType: CREATE,
    });
  });

  it('create + delete drops the row entirely when never attempted', () => {
    expect(coalesceSyncOperation(CREATE, DELETE, true, E)).toEqual({
      kind: 'drop',
    });
  });

  it('create + delete keeps a DELETE tombstone when the create was attempted', () => {
    // An attempted push may have landed its setDoc before the completion
    // write failed — the server may hold a live doc, so the tombstone must
    // push rather than be dropped.
    expect(coalesceSyncOperation(CREATE, DELETE, false, E)).toEqual({
      kind: 'replace',
      operationType: DELETE,
    });
  });

  it('update + update stays update', () => {
    expect(coalesceSyncOperation(UPDATE, UPDATE, true, E)).toEqual({
      kind: 'replace',
      operationType: UPDATE,
    });
  });

  it('update + delete becomes delete (tombstone must push)', () => {
    expect(coalesceSyncOperation(UPDATE, DELETE, true, E)).toEqual({
      kind: 'replace',
      operationType: DELETE,
    });
  });

  it('delete + create resurrects as create', () => {
    expect(coalesceSyncOperation(DELETE, CREATE, true, E)).toEqual({
      kind: 'replace',
      operationType: CREATE,
    });
  });

  it('delete + update resurrects as update', () => {
    expect(coalesceSyncOperation(DELETE, UPDATE, true, E)).toEqual({
      kind: 'replace',
      operationType: UPDATE,
    });
  });
});

describe('coalesceSyncOperation — task_events append-only precedence', () => {
  // Windowed Completion (docs/WINDOWED_COMPLETION.md §Sync): each event is a
  // distinct id, so the coalescer only fires for the SAME event id. A tombstone
  // supersedes a pending create but is NEVER dropped (deterministic backfill
  // ids may live on a peer → the undo must reach the server); undo is final,
  // so a tombstone is never resurrected.
  const { CREATE, DELETE } = SyncOperationType;
  const EV = 'taskEvents';

  it('create + delete keeps a DELETE tombstone even when never attempted (never drops)', () => {
    // The generic path would DROP here; append-only events must NOT — a peer
    // may hold the same deterministic id live, so the undo has to push.
    expect(coalesceSyncOperation(CREATE, DELETE, true, EV)).toEqual({
      kind: 'replace',
      operationType: DELETE,
    });
  });

  it('create + delete keeps a DELETE tombstone when attempted too', () => {
    expect(coalesceSyncOperation(CREATE, DELETE, false, EV)).toEqual({
      kind: 'replace',
      operationType: DELETE,
    });
  });

  it('delete + create does NOT resurrect — undo is final for an event id', () => {
    expect(coalesceSyncOperation(DELETE, CREATE, true, EV)).toEqual({
      kind: 'replace',
      operationType: DELETE,
    });
  });

  it('create + create stays a create (event not yet on server)', () => {
    expect(coalesceSyncOperation(CREATE, CREATE, true, EV)).toEqual({
      kind: 'replace',
      operationType: CREATE,
    });
  });
});

describe('addToSyncQueue — burst coalescing', () => {
  it('collapses an edit burst to ONE pending row with the LAST payload', async () => {
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, {
      id: 't1',
      version: 1,
    });
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, {
      id: 't1',
      version: 2,
    });
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, {
      id: 't1',
      version: 3,
    });

    const rows = await pendingFor('tasks', 't1');
    expect(rows).toHaveLength(1);
    expect(JSON.parse(rows[0].payload)).toMatchObject({ version: 3 });
    expect(rows[0].operationType).toBe(SyncOperationType.UPDATE);
  });

  it('keeps the original queue position (createdAt) when replacing', async () => {
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 1 });
    const first = (await pendingFor('tasks', 't1'))[0];

    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 2 });
    const after = (await pendingFor('tasks', 't1'))[0];

    // Same row (id + createdAt preserved), fresh payload.
    expect(after.id).toBe(first.id);
    expect(after.createdAt).toBe(first.createdAt);
    expect(JSON.parse(after.payload)).toMatchObject({ v: 2 });
  });
});

describe('addToSyncQueue — precedence at the DB layer', () => {
  it('create then update keeps the row as CREATE with refreshed payload', async () => {
    await addToSyncQueue('boards', 'b1', SyncOperationType.CREATE, { v: 1 });
    await addToSyncQueue('boards', 'b1', SyncOperationType.UPDATE, { v: 2 });

    const rows = await pendingFor('boards', 'b1');
    expect(rows).toHaveLength(1);
    expect(rows[0].operationType).toBe(SyncOperationType.CREATE);
    expect(JSON.parse(rows[0].payload)).toMatchObject({ v: 2 });
  });

  it('update then delete becomes a single DELETE row', async () => {
    await addToSyncQueue('boards', 'b1', SyncOperationType.UPDATE, { v: 1 });
    await addToSyncQueue('boards', 'b1', SyncOperationType.DELETE, {
      v: 2,
      isDeleted: true,
    });

    const rows = await pendingFor('boards', 'b1');
    expect(rows).toHaveLength(1);
    expect(rows[0].operationType).toBe(SyncOperationType.DELETE);
  });

  it('create then delete drops the row entirely (never reached the server)', async () => {
    await addToSyncQueue('tasks', 't1', SyncOperationType.CREATE, { v: 1 });
    await addToSyncQueue('tasks', 't1', SyncOperationType.DELETE, {
      v: 2,
      isDeleted: true,
    });

    expect(await pendingFor('tasks', 't1')).toHaveLength(0);
  });

  it('create then delete keeps a DELETE when the create was already attempted', async () => {
    // A pending CREATE whose push was attempted (lastAttemptAt set — e.g.
    // setDoc landed but the completion write failed, then the row was
    // promoted back to PENDING). The server may hold a live doc, so the
    // delete must be kept as a tombstone rather than dropped.
    await db.syncQueue.add({
      id: 'attempted-create',
      entityType: 'tasks',
      entityId: 't1',
      operationType: SyncOperationType.CREATE,
      payload: JSON.stringify({ v: 1 }),
      status: SyncStatus.PENDING,
      retryCount: 1,
      createdAt: new Date().toISOString(),
      lastAttemptAt: new Date().toISOString(),
      priority: 0,
    });

    await addToSyncQueue('tasks', 't1', SyncOperationType.DELETE, {
      v: 2,
      isDeleted: true,
    });

    const rows = await pendingFor('tasks', 't1');
    expect(rows).toHaveLength(1);
    expect(rows[0].operationType).toBe(SyncOperationType.DELETE);
  });

  it('replace preserves lastAttemptAt so a later delete cannot wrongly drop', async () => {
    // Attempted CREATE → an edit (UPDATE) coalesces into it → then a DELETE.
    // The intermediate replace must not erase the attempt evidence.
    const attemptedAt = new Date().toISOString();
    await db.syncQueue.add({
      id: 'attempted-create',
      entityType: 'tasks',
      entityId: 't1',
      operationType: SyncOperationType.CREATE,
      payload: JSON.stringify({ v: 1 }),
      status: SyncStatus.PENDING,
      retryCount: 1,
      createdAt: new Date().toISOString(),
      lastAttemptAt: attemptedAt,
      priority: 0,
    });

    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 2 });

    const afterUpdate = await db.syncQueue.get('attempted-create');
    expect(afterUpdate?.lastAttemptAt).toBe(attemptedAt);

    await addToSyncQueue('tasks', 't1', SyncOperationType.DELETE, {
      v: 3,
      isDeleted: true,
    });

    const rows = await pendingFor('tasks', 't1');
    expect(rows).toHaveLength(1);
    expect(rows[0].operationType).toBe(SyncOperationType.DELETE);
  });

  it('delete then create resurrects as a single CREATE row', async () => {
    await addToSyncQueue('tasks', 't1', SyncOperationType.DELETE, {
      v: 1,
      isDeleted: true,
    });
    await addToSyncQueue('tasks', 't1', SyncOperationType.CREATE, {
      v: 2,
      isDeleted: false,
    });

    const rows = await pendingFor('tasks', 't1');
    expect(rows).toHaveLength(1);
    expect(rows[0].operationType).toBe(SyncOperationType.CREATE);
    expect(JSON.parse(rows[0].payload)).toMatchObject({ isDeleted: false });
  });
});

describe('addToSyncQueue — never coalesces across IN_PROGRESS / FAILED', () => {
  it('appends a fresh PENDING row when an IN_PROGRESS row is mid-flight', async () => {
    await db.syncQueue.add({
      id: 'inflight',
      entityType: 'tasks',
      entityId: 't1',
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify({ v: 1 }),
      status: SyncStatus.IN_PROGRESS,
      retryCount: 0,
      createdAt: new Date().toISOString(),
      priority: 0,
    });

    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 2 });

    // The in-progress row is untouched; a new pending row is appended.
    const all = await db.syncQueue
      .where('[entityType+entityId]')
      .equals(['tasks', 't1'])
      .toArray();
    expect(all).toHaveLength(2);
    const inflight = all.find((r) => r.id === 'inflight');
    expect(inflight?.status).toBe(SyncStatus.IN_PROGRESS);
    expect(JSON.parse(inflight!.payload)).toMatchObject({ v: 1 });
    const pending = await pendingFor('tasks', 't1');
    expect(pending).toHaveLength(1);
    expect(JSON.parse(pending[0].payload)).toMatchObject({ v: 2 });
  });

  it('appends a fresh PENDING row rather than coalescing into a FAILED row', async () => {
    await db.syncQueue.add({
      id: 'failed',
      entityType: 'tasks',
      entityId: 't1',
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify({ v: 1 }),
      status: SyncStatus.FAILED,
      retryCount: 2,
      lastError: 'boom',
      createdAt: new Date().toISOString(),
      priority: 0,
    });

    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 2 });

    const failed = await db.syncQueue.get('failed');
    expect(failed?.status).toBe(SyncStatus.FAILED);
    expect(failed?.retryCount).toBe(2);
    const pending = await pendingFor('tasks', 't1');
    expect(pending).toHaveLength(1);
    expect(JSON.parse(pending[0].payload)).toMatchObject({ v: 2 });
  });
});

describe('addToSyncQueue — cross-entity isolation', () => {
  it('does not coalesce rows for different entities', async () => {
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, { v: 1 });
    await addToSyncQueue('tasks', 't2', SyncOperationType.UPDATE, { v: 1 });
    await addToSyncQueue('boards', 't1', SyncOperationType.UPDATE, { v: 1 });

    expect(await pendingFor('tasks', 't1')).toHaveLength(1);
    expect(await pendingFor('tasks', 't2')).toHaveLength(1);
    expect(await pendingFor('boards', 't1')).toHaveLength(1);
  });
});
