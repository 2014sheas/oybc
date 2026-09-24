import { describe, it, expect, vi, beforeEach } from 'vitest';
import { DEFAULT_USER_PREFERENCES, type User } from '@oybc/shared';

/**
 * Guest-mode stateful invariants (docs/GUEST_MODE.md, CLAUDE.md §Guest Mode):
 *
 *  - Post-link reconcile: linking fires no `onAuthStateChanged`, so
 *    `reconcileAfterUpgrade` (what `AuthContext.refreshAfterUpgrade` runs)
 *    must re-upsert the local user row and recompute `isAnonymous`.
 *  - Collision switch clears ONLY the anon sync queue: `clearSyncQueue` empties
 *    `syncQueue` and leaves the guest's local rows in place.
 *  - Discard wipes everything: `deleteAccount` (the guest "Discard guest data"
 *    path) clears EVERY Dexie store — pinned against IndexedDB's own store
 *    list, so a store skipped by a filter fails here.
 *
 * The auth client is faked by stubbing `../config`'s `auth` with a mutable
 * object (the same seam guestMode.test.ts uses to keep Firebase from
 * initializing); no network, no real Firebase.
 */
const fakeAuth = vi.hoisted(() => ({ currentUser: null as unknown }));
vi.mock('../config', () => ({ auth: fakeAuth, firestore: {} }));

const { db } = await import('../../db/internal');
const { reconcileAfterUpgrade } = await import('../authService');
const { deleteAccount } = await import('../accountSecurity');
const { clearSyncQueue } = await import('../../db/operations/syncQueue');

const ANON_UID = 'anon-uid-0001';

/** The row `signInAnonymously` leaves behind: empty email, no name. */
function anonRow(): User {
  return {
    id: ANON_UID,
    email: '',
    preferences: { ...DEFAULT_USER_PREFERENCES },
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
  };
}

beforeEach(async () => {
  await db.open();
  await Promise.all(db.tables.map((t) => t.clear()));
  fakeAuth.currentUser = null;
});

describe('post-link reconcile (reconcileAfterUpgrade)', () => {
  it('re-upserts the local row with the linked email/name and reports isAnonymous=false', async () => {
    await db.users.put(anonRow());
    // What `linkWithCredential` leaves on auth.currentUser: same uid, now permanent.
    fakeAuth.currentUser = {
      uid: ANON_UID,
      email: 'me@example.com',
      displayName: 'Me',
      photoURL: null,
      isAnonymous: false,
    };

    const result = await reconcileAfterUpgrade();

    const row = await db.users.get(ANON_UID);
    expect(row?.email).toBe('me@example.com');
    expect(row?.displayName).toBe('Me');
    expect(row?.version).toBe(2);
    expect(row?.createdAt).toBe('2026-09-01T00:00:00.000Z'); // same uid → same row, no re-key
    expect(result.user?.email).toBe('me@example.com');
    expect(result.isAnonymous).toBe(false);
  });

  it('reads the anon flag from the session, not a constant (still anonymous → true)', async () => {
    await db.users.put(anonRow());
    fakeAuth.currentUser = { uid: ANON_UID, email: null, displayName: null, photoURL: null, isAnonymous: true };

    const result = await reconcileAfterUpgrade();

    expect(result.isAnonymous).toBe(true);
    expect((await db.users.get(ANON_UID))?.email).toBe('');
  });

  it('is a no-op when signed out', async () => {
    const result = await reconcileAfterUpgrade();
    expect(result).toEqual({ user: null, isAnonymous: false });
    expect(await db.users.count()).toBe(0);
  });
});

describe('collision switch queue clear (clearSyncQueue)', () => {
  it('empties the sync queue and touches nothing else', async () => {
    await db.users.put(anonRow());
    await db.syncQueue.put({ id: 'q1' } as never);
    await db.syncQueue.put({ id: 'q2' } as never);

    await clearSyncQueue();

    expect(await db.syncQueue.count()).toBe(0);
    expect(await db.users.get(ANON_UID)).toBeDefined();
  });
});

describe('discard guest data (deleteAccount) wipes every local store', () => {
  it('db.tables is exactly the set of IndexedDB object stores', async () => {
    const idbStores = Array.from(db.backendDB().objectStoreNames).sort();
    expect(db.tables.map((t) => t.name).sort()).toEqual(idbStores);
    expect(idbStores.length).toBeGreaterThan(0);
  });

  it('leaves no row in any object store', async () => {
    const idbStores = Array.from(db.backendDB().objectStoreNames);
    for (const name of idbStores) {
      await db.table(name).put({ id: `seed-${name}`, userId: ANON_UID });
    }
    for (const name of idbStores) {
      expect(await db.table(name).count(), `seeded ${name}`).toBe(1);
    }
    const deleteAuthUser = vi.fn(async () => {});
    fakeAuth.currentUser = { uid: ANON_UID, isAnonymous: true, delete: deleteAuthUser };

    await deleteAccount();

    expect(deleteAuthUser).toHaveBeenCalledTimes(1);
    for (const name of idbStores) {
      expect(await db.table(name).count(), `store ${name} after wipe`).toBe(0);
    }
  });
});
