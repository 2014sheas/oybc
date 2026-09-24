import { afterEach, describe, expect, it, vi } from 'vitest';

// `authService` imports `./config`, which initializes Firebase at module load
// (throws without `.env.local`, e.g. on CI) — stub it, as guestMode.test does.
vi.mock('../config', () => ({ auth: {}, firestore: {} }));

// Spy on the Firebase sign-out so the test can assert it is NOT reached when
// the pre-sign-out queue clear fails. Everything else in firebase/auth is kept.
const firebaseSignOut = vi.fn().mockResolvedValue(undefined);
vi.mock('firebase/auth', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/auth')>()),
  signOut: (...args: unknown[]) => firebaseSignOut(...args),
}));

const { signOut, SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE } = await import('../authService');
const { db } = await import('../../db/internal');

/**
 * 2026-09 audit (T1, Task 4) — sign-out must never continue past a failed
 * sync-queue clear: a leftover queue would push this user's pending writes
 * under the next account on the device (cross-user leak). Mirrors iOS
 * `AuthService.signOut` → `AuthServiceError.syncQueueClearFailed`.
 */
describe('authService.signOut — sync-queue clear gate', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    firebaseSignOut.mockClear();
  });

  it('aborts sign-out and throws the user-facing error when the queue clear fails', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const failure = new Error('IDB clear failed');
    vi.spyOn(db.syncQueue, 'clear').mockRejectedValue(failure);

    await expect(signOut()).rejects.toThrow(SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE);

    expect(firebaseSignOut).not.toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalledWith(
      '[authService] signOut: sync-queue clear failed, aborting sign-out',
      failure
    );
  });

  it('clears the queue and then signs out of Firebase on the happy path', async () => {
    const clearSpy = vi.spyOn(db.syncQueue, 'clear');

    await signOut();

    expect(clearSpy).toHaveBeenCalledTimes(1);
    expect(firebaseSignOut).toHaveBeenCalledTimes(1);
  });
});
