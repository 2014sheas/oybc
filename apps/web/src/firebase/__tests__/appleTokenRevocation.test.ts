import { afterEach, describe, expect, it, vi } from 'vitest';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a controllable signed-in user instead.
const userDelete = vi.fn();
interface StubUser {
  uid: string;
  delete: typeof userDelete;
  providerData: { providerId: string }[];
}
const authStub: { currentUser: StubUser | null } = { currentUser: null };
vi.mock('../config', () => ({ auth: authStub, firestore: {} }));

// Sync-loop lifecycle is covered by deleteAccountSyncStop.test; stub it here.
vi.mock('../syncService', () => ({
  stopSyncLoop: () => 'me',
  startSyncLoop: () => {},
}));

// The Apple popup + revoke are what's under test; keep the rest of
// firebase/auth real (incl. `OAuthProvider.credentialFromResult`).
const reauthenticateWithPopup = vi.fn();
const revokeAccessToken = vi.fn();
vi.mock('firebase/auth', async (importOriginal) => ({
  ...(await importOriginal<typeof import('firebase/auth')>()),
  reauthenticateWithPopup: (...args: unknown[]) => reauthenticateWithPopup(...args),
  revokeAccessToken: (...args: unknown[]) => revokeAccessToken(...args),
}));

const {
  APPLE_REVOCATION_FAILED_ERROR,
  APPLE_REVOCATION_REQUIRED_ERROR,
  deleteAccount,
  deleteAccountRevokingApple,
  friendlyError,
  providerStateFromIds,
  requiresAppleRevocation,
} = await import('../accountSecurity');
const { db } = await import('../../db/internal');

/** A signed-in stub user with the given linked providers. */
function signIn(...providerIds: string[]): void {
  authStub.currentUser = {
    uid: 'me',
    delete: userDelete,
    providerData: providerIds.map((providerId) => ({ providerId })),
  };
}

/** The Apple popup's `UserCredential`, in the token-response shape the real
 *  `OAuthProvider.credentialFromResult` reads. */
function applePopupResult(accessToken?: string): unknown {
  return {
    user: authStub.currentUser,
    providerId: 'apple.com',
    operationType: 'reauthenticate',
    _tokenResponse: { providerId: 'apple.com', oauthIdToken: 'apple-id-token', oauthAccessToken: accessToken },
  };
}

/** The syncQueue Table instance the delete wipes via `db.tables`. */
function syncQueueTable() {
  const table = db.tables.find((t) => t.name === 'syncQueue');
  if (!table) throw new Error('syncQueue table missing');
  return table;
}

/**
 * App Store 5.1.1(v) parity (ROADMAP Track L → L1): deleting an account with
 * Sign in with Apple linked revokes the Apple token BEFORE the Firebase user is
 * deleted, and a failed revoke never deletes. Mirrors iOS
 * `AuthRecoveryAndRevocationTests`.
 */
describe('accountSecurity — Apple token revocation on delete', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    userDelete.mockReset();
    reauthenticateWithPopup.mockReset();
    revokeAccessToken.mockReset();
    authStub.currentUser = null;
  });

  it('requires a revoke whenever apple.com is linked, never for a guest', () => {
    expect(requiresAppleRevocation(providerStateFromIds(['apple.com']))).toBe(true);
    expect(requiresAppleRevocation(providerStateFromIds(['password', 'apple.com']))).toBe(true);
    expect(requiresAppleRevocation(providerStateFromIds(['password', 'google.com']))).toBe(false);
    expect(requiresAppleRevocation(providerStateFromIds([]))).toBe(false);
  });

  it('derives provider state from ids (deduped count)', () => {
    expect(providerStateFromIds(['password', 'google.com', 'google.com'])).toEqual({
      hasPassword: true,
      hasGoogle: true,
      hasApple: false,
      providerCount: 2,
    });
  });

  it('plain deleteAccount refuses an Apple-linked account and deletes nothing', async () => {
    signIn('password', 'apple.com');

    await expect(deleteAccount()).rejects.toThrow(APPLE_REVOCATION_REQUIRED_ERROR);

    expect(userDelete).not.toHaveBeenCalled();
  });

  it('plain deleteAccount still deletes a guest (no providers)', async () => {
    signIn();
    userDelete.mockResolvedValue(undefined);

    await deleteAccount();

    expect(userDelete).toHaveBeenCalledTimes(1);
    expect(revokeAccessToken).not.toHaveBeenCalled();
  });

  it('reauths with the Apple popup, revokes its token, then deletes and wipes', async () => {
    signIn('password', 'apple.com');
    reauthenticateWithPopup.mockResolvedValue(applePopupResult('fresh-access-token'));
    revokeAccessToken.mockResolvedValue(undefined);
    userDelete.mockResolvedValue(undefined);
    const clearSpy = vi.spyOn(syncQueueTable(), 'clear');

    await deleteAccountRevokingApple();

    expect(reauthenticateWithPopup.mock.calls[0][1]).toMatchObject({ providerId: 'apple.com' });
    expect(revokeAccessToken).toHaveBeenCalledWith(authStub, 'fresh-access-token');
    const [reauthAt] = reauthenticateWithPopup.mock.invocationCallOrder;
    const [revokeAt] = revokeAccessToken.mock.invocationCallOrder;
    const [deleteAt] = userDelete.mock.invocationCallOrder;
    expect(reauthAt).toBeLessThan(revokeAt);
    expect(revokeAt).toBeLessThan(deleteAt);
    expect(clearSpy.mock.invocationCallOrder[0]).toBeGreaterThan(deleteAt);
  });

  it('never deletes when the revoke fails', async () => {
    signIn('apple.com');
    vi.spyOn(console, 'error').mockImplementation(() => {});
    reauthenticateWithPopup.mockResolvedValue(applePopupResult('fresh-access-token'));
    revokeAccessToken.mockRejectedValue(new Error('network'));
    const clearSpy = vi.spyOn(syncQueueTable(), 'clear');

    await expect(deleteAccountRevokingApple()).rejects.toThrow(APPLE_REVOCATION_FAILED_ERROR);

    expect(userDelete).not.toHaveBeenCalled();
    expect(clearSpy).not.toHaveBeenCalled();
  });

  it('never deletes when the popup returns no access token', async () => {
    signIn('apple.com');
    vi.spyOn(console, 'error').mockImplementation(() => {});
    reauthenticateWithPopup.mockResolvedValue(applePopupResult(undefined));

    await expect(deleteAccountRevokingApple()).rejects.toThrow(APPLE_REVOCATION_FAILED_ERROR);

    expect(revokeAccessToken).not.toHaveBeenCalled();
    expect(userDelete).not.toHaveBeenCalled();
  });

  it('stops before revoking when the popup is closed', async () => {
    signIn('apple.com');
    const closed = Object.assign(new Error('closed'), { code: 'auth/popup-closed-by-user' });
    reauthenticateWithPopup.mockRejectedValue(closed);

    await expect(deleteAccountRevokingApple()).rejects.toBe(closed);

    expect(revokeAccessToken).not.toHaveBeenCalled();
    expect(userDelete).not.toHaveBeenCalled();
  });

  it('maps the revoke errors to one-line copy', () => {
    expect(friendlyError(new Error(APPLE_REVOCATION_FAILED_ERROR))).toBe(
      'Couldn’t disconnect Apple, so your account wasn’t deleted. Try again.'
    );
    expect(friendlyError(new Error(APPLE_REVOCATION_REQUIRED_ERROR))).toBe(
      'Confirm with Apple to delete this account.'
    );
  });
});
