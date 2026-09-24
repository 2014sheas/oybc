import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a controllable signed-in user instead. The sync
// service registers `auth.currentUser?.uid` as the enqueue owner provider, so
// flipping `authStub.currentUser` is exactly an account switch.
const authStub: { currentUser: { uid: string } | null } = { currentUser: null };
vi.mock('../config', () => ({ auth: authStub, firestore: {} }));

// Every Firestore write the push path makes goes through `setDoc`; a remote
// that doesn't exist yet makes each owned item a plain "push new".
const getDoc = vi.fn();
const setDoc = vi.fn();
vi.mock('firebase/firestore', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/firestore')>()),
  doc: vi.fn((_fs: unknown, ...segments: string[]) => ({
    path: segments.join('/'),
    parent: { id: segments[segments.length - 2] },
  })),
  getDoc: (...args: unknown[]) => getDoc(...args),
  setDoc: (...args: unknown[]) => setDoc(...args),
}));

const { pushSync } = await import('../syncService');
const { addToSyncQueue } = await import('../../db/operations/syncQueue');
const { db } = await import('../../db/internal');
const { SyncOperationType, SyncStatus } = await import('@oybc/shared');

const ANON = 'anon-uid';
const REAL = 'real-uid';
const PLACEMENT_ID = '11111111-1111-4111-8111-111111111111';
const LEGACY_ID = '22222222-2222-4222-8222-222222222222';

/** A `boardTasks` payload — no `userId` field, so rules can't catch a cross-account push. */
function placement(id: string): Record<string, unknown> {
  return { id, boardId: 'b1', taskId: 't1', position: 0, version: 1, isDeleted: false };
}

/** The Firestore paths the push wrote, in order. */
function writtenPaths(): string[] {
  return setDoc.mock.calls.map((call) => (call[0] as { path: string }).path);
}

/**
 * docs/GUEST_MODE.md §Collision — every queue item is stamped with the uid
 * signed in at enqueue; `pushSync` drops (never pushes) items owned by another
 * uid, so the discarded guest's `boardTasks` can't be accepted into the real
 * account during the switch race. Legacy unstamped rows push as before.
 */
describe('sync queue ownership — push drops foreign-owned items', () => {
  let warn: ReturnType<typeof vi.spyOn>;

  beforeEach(async () => {
    await db.syncQueue.clear();
    getDoc.mockResolvedValue({ exists: () => false });
    setDoc.mockResolvedValue(undefined);
    warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    getDoc.mockReset();
    setDoc.mockReset();
    authStub.currentUser = null;
    await db.syncQueue.clear();
  });

  it('stamps the signed-in uid on enqueue', async () => {
    authStub.currentUser = { uid: ANON };
    await addToSyncQueue('boardTasks', PLACEMENT_ID, SyncOperationType.CREATE, placement(PLACEMENT_ID));

    const [row] = await db.syncQueue.toArray();
    expect(row.ownerUid).toBe(ANON);
  });

  it('an item queued under uid A is dropped, not pushed, when pushing as uid B', async () => {
    authStub.currentUser = { uid: ANON };
    await addToSyncQueue('boardTasks', PLACEMENT_ID, SyncOperationType.CREATE, placement(PLACEMENT_ID));

    authStub.currentUser = { uid: REAL }; // the collision switch
    const result = await pushSync(REAL);

    expect(setDoc).not.toHaveBeenCalled();
    expect(result.pushed).toBe(0);
    expect(await db.syncQueue.count()).toBe(0);
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining(`dropped boardTasks/${PLACEMENT_ID}`)
    );
  });

  it('an item queued under the pushing uid is pushed', async () => {
    authStub.currentUser = { uid: REAL };
    await addToSyncQueue('boardTasks', PLACEMENT_ID, SyncOperationType.CREATE, placement(PLACEMENT_ID));

    const result = await pushSync(REAL);

    expect(result.pushed).toBe(1);
    expect(writtenPaths()).toEqual([`users/${REAL}/boardTasks/${PLACEMENT_ID}`]);
    expect(warn).not.toHaveBeenCalled();
  });

  it('a legacy unstamped item pushes as before', async () => {
    await db.syncQueue.add({
      id: '33333333-3333-4333-8333-333333333333',
      entityType: 'boardTasks',
      entityId: LEGACY_ID,
      operationType: SyncOperationType.CREATE,
      payload: JSON.stringify(placement(LEGACY_ID)),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: '2026-09-24T00:00:00.000Z',
      priority: 0,
    });

    authStub.currentUser = { uid: REAL };
    const result = await pushSync(REAL);

    expect(result.pushed).toBe(1);
    expect(writtenPaths()).toEqual([`users/${REAL}/boardTasks/${LEGACY_ID}`]);
  });

  it("a new owner's edit never coalesces into another owner's pending row", async () => {
    authStub.currentUser = { uid: ANON };
    await addToSyncQueue('boardTasks', PLACEMENT_ID, SyncOperationType.CREATE, placement(PLACEMENT_ID));
    authStub.currentUser = { uid: REAL };
    await addToSyncQueue('boardTasks', PLACEMENT_ID, SyncOperationType.UPDATE, placement(PLACEMENT_ID));

    const owners = (await db.syncQueue.toArray()).map((row) => row.ownerUid).sort();
    expect(owners).toEqual([ANON, REAL]);

    // Only REAL's row reaches Firestore; ANON's is dropped.
    const result = await pushSync(REAL);
    expect(result.pushed).toBe(1);
    expect(setDoc).toHaveBeenCalledTimes(1);
  });
});
