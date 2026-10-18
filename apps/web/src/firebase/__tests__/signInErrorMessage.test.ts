import { describe, expect, it, vi } from 'vitest';

// `authService` imports `./config`, which initializes Firebase at module load
// (throws without `.env.local`, e.g. on CI) — stub it, as guestMode.test does.
vi.mock('../config', () => ({ auth: {}, firestore: {} }));

const { signInErrorMessage } = await import('../authService');

/** A Firebase-shaped auth error carrying `code`. */
function authError(code: string): Error {
  return Object.assign(new Error(`Firebase: Error (${code}).`), { code });
}

/**
 * Sign-in error copy (release audit, ROADMAP Track L → L1): the signed-out
 * sign-in modal never shows Firebase's raw message, a closed popup shows
 * nothing, and a wrong password reads the same as an unknown address. Mirrors
 * iOS `SignInErrorMessageTests`.
 */
describe('authService.signInErrorMessage', () => {
  it.each([
    'auth/invalid-credential',
    'auth/invalid-login-credentials',
    'auth/wrong-password',
    'auth/user-not-found',
  ])('maps %s to the one credentials message', (code) => {
    expect(signInErrorMessage(authError(code))).toBe('Incorrect email or password.');
  });

  it.each([
    ['auth/invalid-email', 'That email address looks invalid.'],
    ['auth/email-already-in-use', 'That email is already in use by another account.'],
    ['auth/weak-password', 'Pick a stronger password (at least 6 characters).'],
    ['auth/too-many-requests', 'Too many attempts. Try again later.'],
    ['auth/user-disabled', 'This account has been disabled.'],
    ['auth/account-exists-with-different-credential', 'This email uses a different sign-in method.'],
    ['auth/network-request-failed', 'You’re offline. Connect and try again.'],
  ])('maps %s to short copy', (code, message) => {
    expect(signInErrorMessage(authError(code))).toBe(message);
  });

  it.each(['auth/popup-closed-by-user', 'auth/cancelled-popup-request', 'auth/user-cancelled'])(
    'shows nothing for a closed popup (%s)',
    (code) => {
      expect(signInErrorMessage(authError(code))).toBeNull();
    }
  );

  it('falls back to plain copy for anything else, never the raw message', () => {
    const fallback = 'Something went wrong. Please try again.';
    expect(signInErrorMessage(authError('auth/internal-error'))).toBe(fallback);
    expect(signInErrorMessage(new Error('Firebase: Error (auth/whatever).'))).toBe(fallback);
    expect(signInErrorMessage(undefined)).toBe(fallback);
    expect(signInErrorMessage(null)).toBe(fallback);
  });
});
