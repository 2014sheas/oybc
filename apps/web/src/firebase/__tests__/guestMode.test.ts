import { describe, it, expect, vi } from 'vitest';

// `authService`/`accountSecurity` transitively import `./config`, which calls
// `getAuth(initializeApp(...))` at module load — that throws `auth/invalid-api-key`
// on CI, where there's no `.env.local` (the same firebase-free-import hazard that
// keeps `db/operations` off firebase; see taskEventPull.ts's header). Stub the
// config module so importing the pure predicates never initializes Firebase.
// Dynamic imports (below) keep the static-import block clean for `import/first`.
vi.mock('../config', () => ({ auth: {}, firestore: {} }));

const { isOfflineError } = await import('../authService');
const { isCredentialCollision, friendlyError } = await import('../accountSecurity');

/**
 * Unit coverage for the pure predicates guest mode adds (docs/GUEST_MODE.md).
 * The stateful flows (anon sign-in, link/upgrade, collision→discard) are
 * exercised via the UI + manual/device verification — these lock the
 * decision logic that gates them.
 */
describe('guest mode — error predicates', () => {
  describe('isOfflineError', () => {
    it('is true only for the network-request-failed code (the one offline-first dent)', () => {
      expect(isOfflineError({ code: 'auth/network-request-failed' })).toBe(true);
    });
    it('is false for other auth errors and non-errors', () => {
      expect(isOfflineError({ code: 'auth/operation-not-allowed' })).toBe(false);
      expect(isOfflineError({ code: 'auth/wrong-password' })).toBe(false);
      expect(isOfflineError(new Error('boom'))).toBe(false);
      expect(isOfflineError(undefined)).toBe(false);
      expect(isOfflineError(null)).toBe(false);
    });
  });

  describe('isCredentialCollision', () => {
    it('is true for both collision codes (the guest-upgrade discard branch)', () => {
      expect(isCredentialCollision({ code: 'auth/credential-already-in-use' })).toBe(true);
      expect(isCredentialCollision({ code: 'auth/email-already-in-use' })).toBe(true);
    });
    it('is false for non-collision errors', () => {
      expect(isCredentialCollision({ code: 'auth/network-request-failed' })).toBe(false);
      expect(isCredentialCollision({ code: 'auth/weak-password' })).toBe(false);
      expect(isCredentialCollision(undefined)).toBe(false);
    });
  });

  describe('friendlyError never leaks a raw provider code for the collision cases', () => {
    it('maps both collision codes to human copy', () => {
      const a = friendlyError({ code: 'auth/credential-already-in-use' });
      const b = friendlyError({ code: 'auth/email-already-in-use' });
      expect(a).not.toContain('auth/');
      expect(b).not.toContain('auth/');
      expect(a.length).toBeGreaterThan(0);
      expect(b.length).toBeGreaterThan(0);
    });
    it('falls back to a generic message for unknown codes', () => {
      expect(friendlyError({ code: 'auth/some-new-code' })).toBe('Something went wrong. Please try again.');
    });
  });
});
