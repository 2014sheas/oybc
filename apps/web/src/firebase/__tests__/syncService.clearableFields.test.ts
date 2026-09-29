import { afterEach, describe, expect, it, vi } from 'vitest';
import { SyncOperationType, type SyncableEntity } from '@oybc/shared';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a signed-in user. The injected doc store below
// means the real Firestore handle is never used. See
// `syncPushOrchestration.test.ts` for the established pattern.
vi.mock('../config', () => ({ auth: { currentUser: { uid: 'me' } }, firestore: {} }));

const { pushSync } = await import('../syncService');
const { db } = await import('../../db/internal');
const { addToSyncQueue } = await import('../../db/operations/syncQueue');

const USER = 'me';
const BOARD_ID = 'board-1';
const PATH = `users/${USER}/boards/${BOARD_ID}`;

/** In-memory `SyncDocStore`: a path → doc map plus a log of every write. */
function makeFakeStore(docs: Record<string, SyncableEntity> = {}) {
  const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
  const store = {
    async getDoc(path: string) {
      return docs[path] ?? null;
    },
    async setDoc(path: string, data: Record<string, unknown>) {
      writes.push({ path, data });
    },
  };
  return { store, writes };
}

/** A minimal board-shaped syncable row — only the fields this suite cares about. */
function boardRow(over: Partial<SyncableEntity> = {}): SyncableEntity {
  return {
    id: BOARD_ID,
    userId: USER,
    version: 2,
    updatedAt: '2026-07-10T00:00:00.000Z',
    isDeleted: false,
    ...over,
  };
}

async function enqueueLocal(local: SyncableEntity): Promise<void> {
  await db.table('boards').put(local);
  await addToSyncQueue('boards', BOARD_ID, SyncOperationType.UPDATE, local);
}

/**
 * Board Edit redesign slice 4 (T2, D2) — `CLEARABLE_BOARD_FIELDS` push
 * wiring: a board field that is ABSENT from the local payload (cleared)
 * writes an explicit Firestore field-delete sentinel, since writes are
 * `merge: true` and would otherwise preserve the stale remote value.
 */
describe('pushSync — CLEARABLE_BOARD_FIELDS field-delete wiring (D2)', () => {
  afterEach(async () => {
    await db.syncQueue.clear();
    await db.table('boards').clear();
    vi.restoreAllMocks();
  });

  it('a reopened board (sealedAt + sealedCompletedCells cleared) pushes deleteField() for both', async () => {
    const local = boardRow(); // no sealedAt / sealedCompletedCells — a Reopen
    const { store, writes } = makeFakeStore();
    await enqueueLocal(local);

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 1, failed: 0 });
    expect(writes).toHaveLength(1);
    expect(writes[0].path).toBe(PATH);
    // Real Firestore `deleteField()` sentinels aren't plain objects with a
    // stable shape to snapshot-match; assert the KEYS are present (the field
    // was NOT simply omitted) and that ordinary fields are untouched.
    expect(Object.keys(writes[0].data)).toEqual(
      expect.arrayContaining(['sealedAt', 'sealedCompletedCells', 'endDate', 'completedAt']),
    );
    expect(writes[0].data.version).toBe(2);
  });

  it('endDate / completedAt clearing behavior is unchanged (both still deleteField() when absent)', async () => {
    const local = boardRow({ sealedAt: '2026-07-02T00:00:00.000Z', sealedCompletedCells: [0, 1] });
    const { store, writes } = makeFakeStore();
    await enqueueLocal(local);

    await pushSync(USER, { store });

    expect(Object.keys(writes[0].data)).toEqual(expect.arrayContaining(['endDate', 'completedAt']));
    // sealedAt / sealedCompletedCells ARE present locally — pushed as real values, not deletes.
    expect(writes[0].data.sealedAt).toBe('2026-07-02T00:00:00.000Z');
    expect(writes[0].data.sealedCompletedCells).toEqual([0, 1]);
  });

  it('a coreBoardDefaults row with its size / centre overrides cleared pushes deleteField() for both (2026-09-29)', async () => {
    const CBD_ID = 'cbd-1';
    const row: SyncableEntity = {
      id: CBD_ID,
      userId: USER,
      version: 3,
      updatedAt: '2026-09-29T00:00:00.000Z',
      isDeleted: false,
    }; // no defaultBoardSize / defaultCenterType — cleared back to inherit
    await db.table('coreBoardDefaults').put(row);
    await addToSyncQueue('coreBoardDefaults', CBD_ID, SyncOperationType.UPDATE, row);
    const { store, writes } = makeFakeStore();

    const result = await pushSync(USER, { store });

    expect(result).toMatchObject({ pushed: 1, failed: 0 });
    expect(writes[0].path).toBe(`users/${USER}/coreBoardDefaults/${CBD_ID}`);
    expect(Object.keys(writes[0].data)).toEqual(
      expect.arrayContaining(['defaultBoardSize', 'defaultCenterType']),
    );
    // The boards-only fields must NOT leak onto a coreBoardDefaults doc.
    expect(writes[0].data).not.toHaveProperty('sealedAt');
    expect(writes[0].data).not.toHaveProperty('endDate');
    await db.syncQueue.clear();
    await db.table('coreBoardDefaults').clear();
  });

  it('a coreBoardDefaults row with its overrides SET pushes the real values, not deletes', async () => {
    const CBD_ID = 'cbd-2';
    const row = {
      id: CBD_ID,
      userId: USER,
      version: 1,
      updatedAt: '2026-09-29T00:00:00.000Z',
      isDeleted: false,
      defaultBoardSize: 4,
      defaultCenterType: 'none',
    } as SyncableEntity;
    await db.table('coreBoardDefaults').put(row);
    await addToSyncQueue('coreBoardDefaults', CBD_ID, SyncOperationType.UPDATE, row);
    const { store, writes } = makeFakeStore();

    await pushSync(USER, { store });

    expect(writes[0].data.defaultBoardSize).toBe(4);
    expect(writes[0].data.defaultCenterType).toBe('none');
    await db.syncQueue.clear();
    await db.table('coreBoardDefaults').clear();
  });

  it('a non-board entity type never gets the clearable-field treatment', async () => {
    await db.table('tasks').put({ id: 't1', userId: USER, version: 1, updatedAt: '2026-07-10T00:00:00.000Z', isDeleted: false });
    await addToSyncQueue('tasks', 't1', SyncOperationType.UPDATE, {
      id: 't1',
      userId: USER,
      version: 1,
      updatedAt: '2026-07-10T00:00:00.000Z',
      isDeleted: false,
    });
    const { store, writes } = makeFakeStore();

    await pushSync(USER, { store });

    expect(writes[0].data).not.toHaveProperty('sealedAt');
    expect(writes[0].data).not.toHaveProperty('endDate');
    await db.syncQueue.clear();
    await db.table('tasks').clear();
  });
});
