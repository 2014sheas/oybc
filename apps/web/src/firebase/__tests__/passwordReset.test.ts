import { afterEach, describe, expect, it, vi } from 'vitest';

// `authService` imports `./config`, which initializes Firebase at module load
// (throws without `.env.local`, e.g. on CI) — stub it, as guestMode.test does.
vi.mock('../config', () => ({ auth: {}, firestore: {} }));

// Spy on the Firebase send so each case can choose its outcome; everything
// else in firebase/auth is kept.
const sendPasswordResetEmail = vi.fn();
vi.mock('firebase/auth', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/auth')>()),
  sendPasswordResetEmail: (...args: unknown[]) => sendPasswordResetEmail(...args),
}));

const { sendPasswordReset, resetErrorCountsAsSent, passwordResetSentStatus } = await import(
  '../authService'
);

/** A Firebase-shaped auth error carrying `code`. */
function authError(code: string): Error {
  return Object.assign(new Error(`Firebase: Error (${code}).`), { code });
}

/**
 * ROADMAP Track L → L1 — the signed-out "Forgot password?" action must read
 * the same whether or not an account uses the address (no account
 * enumeration), while real failures still reach the form. Mirrors iOS
 * `AuthRecoveryAndRevocationTests` (PasswordReset + sendPasswordReset(toEmail:)).
 */
describe('authService — signed-out password reset', () => {
  afterEach(() => {
    sendPasswordResetEmail.mockReset();
  });

  it('sends to the trimmed address and returns it', async () => {
    sendPasswordResetEmail.mockResolvedValue(undefined);

    await expect(sendPasswordReset('  me@example.com ')).resolves.toBe('me@example.com');

    expect(sendPasswordResetEmail).toHaveBeenCalledTimes(1);
    expect(sendPasswordResetEmail.mock.calls[0][1]).toBe('me@example.com');
  });

  it('resolves exactly like a send when no account uses the address', async () => {
    sendPasswordResetEmail.mockRejectedValue(authError('auth/user-not-found'));

    await expect(sendPasswordReset('nobody@example.com')).resolves.toBe('nobody@example.com');
  });

  it.each(['auth/invalid-email', 'auth/network-request-failed', 'auth/too-many-requests'])(
    'rejects with the Firebase error for %s',
    async (code) => {
      const failure = authError(code);
      sendPasswordResetEmail.mockRejectedValue(failure);

      await expect(sendPasswordReset('me@example.com')).rejects.toBe(failure);
    }
  );

  it('treats only user-not-found as sent', () => {
    expect(resetErrorCountsAsSent({ code: 'auth/user-not-found' })).toBe(true);
    expect(resetErrorCountsAsSent({ code: 'auth/invalid-email' })).toBe(false);
    expect(resetErrorCountsAsSent(new Error('boom'))).toBe(false);
    expect(resetErrorCountsAsSent(undefined)).toBe(false);
    expect(resetErrorCountsAsSent(null)).toBe(false);
  });

  it('names the address in the status line', () => {
    expect(passwordResetSentStatus('me@example.com')).toBe('Reset link sent to me@example.com');
  });
});
