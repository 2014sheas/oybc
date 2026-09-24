import { afterEach, describe, expect, it, vi } from 'vitest';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a controllable signed-in user instead.
const userDelete = vi.fn();
const authStub: { currentUser: { uid: string; delete: typeof userDelete } | null } = {
  currentUser: { uid: 'me', delete: userDelete },
};
vi.mock('../config', () => ({ auth: authStub, firestore: {} }));

// The loop's lifecycle is what's under test; stub it so no real listeners open.
const stopSyncLoop = vi.fn<() => string | null>();
const startSyncLoop = vi.fn();
vi.mock('../syncService', () => ({
  stopSyncLoop: () => stopSyncLoop(),
  startSyncLoop: (...args: unknown[]) => startSyncLoop(...args),
}));

const { deleteAccount } = await import('../accountSecurity');
const { db } = await import('../../db/internal');

/** The syncQueue Table instance `deleteAccount` iterates via `db.tables`. */
function syncQueueTable() {
  const table = db.tables.find((t) => t.name === 'syncQueue');
  if (!table) throw new Error('syncQueue table missing');
  return table;
}

/**
 * 2026-09 audit (T1, Task 6) — web `deleteAccount` must stop the sync loop
 * BEFORE deleting the Auth user, so no push can race the server-side purge
 * and resurrect the just-deleted Firestore data (iOS stops its SyncService
 * during deleteAccount too). A failed delete leaves the account intact, so the
 * loop it stopped is restarted.
 */
describe('accountSecurity.deleteAccount — sync loop ordering', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    userDelete.mockReset();
    stopSyncLoop.mockReset();
    startSyncLoop.mockReset();
  });

  it('stops the sync loop before user.delete(), then wipes the tables', async () => {
    stopSyncLoop.mockReturnValue('me');
    userDelete.mockResolvedValue(undefined);
    const clearSpy = vi.spyOn(syncQueueTable(), 'clear');

    await deleteAccount();

    expect(stopSyncLoop).toHaveBeenCalledTimes(1);
    expect(userDelete).toHaveBeenCalledTimes(1);
    expect(stopSyncLoop.mock.invocationCallOrder[0]).toBeLessThan(
      userDelete.mock.invocationCallOrder[0]
    );
    expect(clearSpy.mock.invocationCallOrder[0]).toBeGreaterThan(
      userDelete.mock.invocationCallOrder[0]
    );
    expect(startSyncLoop).not.toHaveBeenCalled();
  });

  it('restarts the stopped loop and rethrows when the delete fails, wiping nothing', async () => {
    stopSyncLoop.mockReturnValue('me');
    const failure = Object.assign(new Error('recent login'), {
      code: 'auth/requires-recent-login',
    });
    userDelete.mockRejectedValue(failure);
    const clearSpy = vi.spyOn(syncQueueTable(), 'clear');

    await expect(deleteAccount()).rejects.toBe(failure);

    expect(startSyncLoop).toHaveBeenCalledWith('me');
    expect(clearSpy).not.toHaveBeenCalled();
  });

  it('does not start a loop on failure when none was running', async () => {
    stopSyncLoop.mockReturnValue(null);
    userDelete.mockRejectedValue(new Error('boom'));

    await expect(deleteAccount()).rejects.toThrow('boom');

    expect(startSyncLoop).not.toHaveBeenCalled();
  });
});
