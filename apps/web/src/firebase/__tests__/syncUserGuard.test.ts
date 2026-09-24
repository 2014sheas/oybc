import { afterEach, describe, expect, it, vi } from 'vitest';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a controllable signed-in user instead.
const authStub: { currentUser: { uid: string } | null } = { currentUser: { uid: 'me' } };
vi.mock('../config', () => ({ auth: authStub, firestore: {} }));

// Spy on every Firestore entry point the sync paths use, so the test can
// prove a mismatched uid is rejected BEFORE any network call.
const getDoc = vi.fn();
const getDocs = vi.fn();
const setDoc = vi.fn();
const onSnapshot = vi.fn();
vi.mock('firebase/firestore', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/firestore')>()),
  doc: vi.fn(() => ({})),
  collection: vi.fn(() => ({})),
  query: vi.fn(() => ({})),
  getDoc: (...args: unknown[]) => getDoc(...args),
  getDocs: (...args: unknown[]) => getDocs(...args),
  setDoc: (...args: unknown[]) => setDoc(...args),
  onSnapshot: (...args: unknown[]) => onSnapshot(...args),
}));

const { pushSync, pullSync, fullSync, startSyncLoop, stopSyncLoop } = await import(
  '../syncService'
);
const { db } = await import('../../db/internal');

const MISMATCH = 'Sync userId does not match authenticated user';

/**
 * 2026-09 audit (T1, Task 6) — the uid guard used to live only in `fullSync`,
 * so the loop's direct `pushTick → pushSync` path could push under a uid that
 * is no longer signed in. It now runs at the top of `pushSync` and `pullSync`
 * too. iOS twin: the `currentUser?.uid == userId` guard in `pushSyncCore`.
 */
describe('sync entry points — authenticated-uid guard', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    getDoc.mockReset();
    getDocs.mockReset();
    setDoc.mockReset();
    onSnapshot.mockReset();
    authStub.currentUser = { uid: 'me' };
  });

  it('pushSync for another uid throws before touching Dexie or Firestore', async () => {
    const whereSpy = vi.spyOn(db.syncQueue, 'where');

    await expect(pushSync('other-uid')).rejects.toThrow(MISMATCH);

    expect(whereSpy).not.toHaveBeenCalled();
    expect(getDoc).not.toHaveBeenCalled();
    expect(getDocs).not.toHaveBeenCalled();
    expect(setDoc).not.toHaveBeenCalled();
  });

  it('pullSync for another uid throws before touching Firestore', async () => {
    await expect(pullSync('other-uid')).rejects.toThrow(MISMATCH);

    expect(getDoc).not.toHaveBeenCalled();
    expect(getDocs).not.toHaveBeenCalled();
  });

  it('pushSync and pullSync throw when nobody is signed in', async () => {
    authStub.currentUser = null;

    await expect(pushSync('me')).rejects.toThrow(MISMATCH);
    await expect(pullSync('me')).rejects.toThrow(MISMATCH);
    expect(getDoc).not.toHaveBeenCalled();
  });

  it('fullSync for another uid throws before reading the local user row', async () => {
    const usersGet = vi.spyOn(db.users, 'get');

    await expect(fullSync('other-uid')).rejects.toThrow(MISMATCH);

    expect(usersGet).not.toHaveBeenCalled();
    expect(getDoc).not.toHaveBeenCalled();
  });

  it('pushSync for the signed-in uid gets past the guard into the queue', async () => {
    const whereSpy = vi.spyOn(db.syncQueue, 'where');

    // Whatever the queue read does under fake-indexeddb, it must not be the
    // uid-mismatch rejection — the guard lets the signed-in uid through.
    const outcome = await pushSync('me').then(
      () => null,
      (err: unknown) => err
    );

    expect(outcome instanceof Error ? outcome.message : '').not.toBe(MISMATCH);
    expect(whereSpy).toHaveBeenCalled();
  });
});

/**
 * `stopSyncLoop` (added for web `deleteAccount`) stops the one running loop
 * from outside React. The loop is registered module-wide; the hook's cleanup
 * and `stopSyncLoop` may both reach the same teardown.
 */
describe('startSyncLoop / stopSyncLoop — single active loop', () => {
  const addEventListener = vi.fn();
  const removeEventListener = vi.fn();

  function stubWindow(): void {
    vi.stubGlobal('window', { addEventListener, removeEventListener });
    // Node 20 (CI) has no global `navigator` (Node 21 added it); the loop's
    // immediate tick reads `navigator.onLine`. Stub it OFFLINE so every tick
    // is a no-op here — these tests cover teardown, not syncing.
    vi.stubGlobal('navigator', { onLine: false });
  }

  afterEach(() => {
    stopSyncLoop();
    vi.unstubAllGlobals();
    addEventListener.mockReset();
    removeEventListener.mockReset();
  });

  it('returns null when no loop is running', () => {
    expect(stopSyncLoop()).toBeNull();
  });

  it('stops the running loop once, reporting its uid, and tears it down', () => {
    stubWindow();
    startSyncLoop('me', 60_000);

    expect(stopSyncLoop()).toBe('me');
    expect(removeEventListener).toHaveBeenCalledWith('online', expect.any(Function));
    expect(stopSyncLoop()).toBeNull();
  });

  it("the hook's cleanup is idempotent after stopSyncLoop already ran", () => {
    stubWindow();
    const cleanup = startSyncLoop('me', 60_000);

    stopSyncLoop();
    cleanup();

    expect(removeEventListener).toHaveBeenCalledTimes(1);
  });

  it("the hook's cleanup also stops a loop restarted for the same uid outside React", () => {
    stubWindow();
    const cleanup = startSyncLoop('me', 60_000);
    stopSyncLoop();
    startSyncLoop('me', 60_000); // e.g. deleteAccount's failed-delete resume

    cleanup();

    expect(stopSyncLoop()).toBeNull();
    expect(removeEventListener).toHaveBeenCalledTimes(2);
  });

  it('a new start replaces the running loop', () => {
    stubWindow();
    startSyncLoop('me', 60_000);
    startSyncLoop('you', 60_000);

    expect(removeEventListener).toHaveBeenCalledTimes(1);
    expect(stopSyncLoop()).toBe('you');
  });
});
