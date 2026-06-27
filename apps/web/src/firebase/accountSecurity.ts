/**
 * Account & security operations (web counterpart of iOS AuthService §5c +
 * ProviderState). Pure functions over Firebase Auth, mirroring the iOS
 * behavior 1:1 — change email/password, reauthentication, provider linking,
 * and (Phase 5b-iii) account deletion.
 *
 * Reauth note: security-sensitive ops (updatePassword/Email, delete, unlink)
 * throw `auth/requires-recent-login` when the login is stale. Callers should
 * catch via `isRecentLoginRequired`, run a reauth flow, and retry.
 */
import {
  EmailAuthProvider,
  GoogleAuthProvider,
  OAuthProvider,
  linkWithCredential,
  linkWithPopup,
  reauthenticateWithCredential,
  reauthenticateWithPopup,
  sendPasswordResetEmail,
  unlink as fbUnlink,
  updatePassword as fbUpdatePassword,
  verifyBeforeUpdateEmail,
  type AuthError,
} from 'firebase/auth';
import { auth } from './config';
import { db } from '../db/database';
import { updateUserEmail } from '../db/operations/users';

// ─── Provider state ─────────────────────────────────────────────────────────

export const PASSWORD_PROVIDER_ID = 'password';
export const GOOGLE_PROVIDER_ID = 'google.com';
export const APPLE_PROVIDER_ID = 'apple.com';

/** Which sign-in methods are linked to the current account. Gates the UI:
 *  change-email/password need a password provider; unlink is blocked at one. */
export interface ProviderState {
  hasPassword: boolean;
  hasGoogle: boolean;
  hasApple: boolean;
  providerCount: number;
}

export const EMPTY_PROVIDER_STATE: ProviderState = {
  hasPassword: false,
  hasGoogle: false,
  hasApple: false,
  providerCount: 0,
};

/**
 * Read the current account's linked-provider state. Reloads the Firebase user
 * first so it reflects any out-of-band changes (mirrors iOS refreshProviderState).
 */
export async function getProviderState(): Promise<ProviderState> {
  const user = auth.currentUser;
  if (!user) return EMPTY_PROVIDER_STATE;
  try {
    await user.reload();
  } catch {
    // Reload can fail offline; fall back to the cached providerData.
  }
  const ids = new Set((auth.currentUser?.providerData ?? []).map((p) => p.providerId));
  return {
    hasPassword: ids.has(PASSWORD_PROVIDER_ID),
    hasGoogle: ids.has(GOOGLE_PROVIDER_ID),
    hasApple: ids.has(APPLE_PROVIDER_ID),
    providerCount: ids.size,
  };
}

/** True when an error is Firebase's `requires-recent-login` — the cue to run a
 *  reauth flow and retry the security-sensitive operation. */
export function isRecentLoginRequired(error: unknown): boolean {
  return (error as AuthError | undefined)?.code === 'auth/requires-recent-login';
}

// ─── Reauthentication ───────────────────────────────────────────────────────

/** Reauthenticate a password user (refreshes login recency). */
export async function reauthWithPassword(password: string): Promise<void> {
  const user = auth.currentUser;
  if (!user || !user.email) throw new Error('No signed-in user');
  const credential = EmailAuthProvider.credential(user.email, password);
  await reauthenticateWithCredential(user, credential);
}

/** Reauthenticate via the Google popup handshake. */
export async function reauthWithGoogle(): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  await reauthenticateWithPopup(user, new GoogleAuthProvider());
}

/** Reauthenticate via the Apple popup handshake. */
export async function reauthWithApple(): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  const provider = new OAuthProvider('apple.com');
  provider.addScope('email');
  await reauthenticateWithPopup(user, provider);
}

// ─── Change email / password ────────────────────────────────────────────────

/** Update the account password. Password-provider only; needs recent login. */
export async function updateAccountPassword(newPassword: string): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  await fbUpdatePassword(user, newPassword);
}

/**
 * Begin an email change via `verifyBeforeUpdateEmail` (the supported path —
 * direct `updateEmail` is rejected under email-enumeration protection).
 * Firebase emails a verification link to the NEW address; `currentUser.email`
 * only swaps once the user clicks it. The local mirror is healed later by
 * `reconcileEmailIfChanged`. Needs recent login.
 */
export async function updateAccountEmail(newEmail: string): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  await verifyBeforeUpdateEmail(user, newEmail.trim());
}

/**
 * Heal the local + Firestore email if the verified Firebase email now differs
 * from the locally-stored one (the user completed a verifyBeforeUpdateEmail
 * flow out-of-band). Safe to call on mount; a no-op when nothing changed.
 */
export async function reconcileEmailIfChanged(): Promise<void> {
  const user = auth.currentUser;
  if (!user) return;
  try {
    await user.reload();
  } catch {
    return;
  }
  const firebaseEmail = auth.currentUser?.email;
  if (!firebaseEmail) return;
  const local = await db.users.get(user.uid);
  if (!local || local.email === firebaseEmail) return;
  await updateUserEmail(user.uid, firebaseEmail);
}

/** Send a password-reset email to the signed-in user — an escape hatch for
 *  changing the password without knowing the current one. No reauth needed. */
export async function sendPasswordResetToCurrentUser(): Promise<void> {
  const email = auth.currentUser?.email;
  if (!email) throw new Error('No signed-in user');
  await sendPasswordResetEmail(auth, email);
}

// ─── Add a password (link) ──────────────────────────────────────────────────

/**
 * Add an email/password sign-in method to an OAuth-only account, unlocking
 * change-email / change-password. Treats "already linked" as an idempotent
 * success.
 */
export async function linkPassword(email: string, password: string): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  const credential = EmailAuthProvider.credential(email, password);
  try {
    await linkWithCredential(user, credential);
  } catch (error) {
    if ((error as AuthError).code === 'auth/provider-already-linked') return;
    throw error;
  }
}

// ─── Connected accounts: link / unlink (Phase 5b-ii) ──────────────────────────

/** Link a Google identity to the current account via popup. Idempotent on
 *  "already linked"; `credential-already-in-use` (the Google account is on
 *  ANOTHER OYBC account) propagates for the UI to surface. */
export async function linkGoogle(): Promise<void> {
  await linkProvider(new GoogleAuthProvider());
}

/** Link an Apple identity to the current account via popup. */
export async function linkApple(): Promise<void> {
  const provider = new OAuthProvider('apple.com');
  provider.addScope('email');
  provider.addScope('name');
  await linkProvider(provider);
}

/** Shared popup-link path: idempotent on already-linked; refreshes nothing
 *  (callers re-read provider state). Other errors (incl. credential-already-in-use)
 *  propagate. */
async function linkProvider(provider: GoogleAuthProvider | OAuthProvider): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  try {
    await linkWithPopup(user, provider);
  } catch (error) {
    if ((error as AuthError).code === 'auth/provider-already-linked') return;
    throw error;
  }
}

/** Error thrown when the user tries to unlink their only remaining sign-in
 *  method (would lock them out). Callers should block this in the UI too. */
export const LAST_PROVIDER_ERROR = 'cannot-unlink-last-provider';

/**
 * Unlink a provider (`google.com` / `apple.com` / `password`). Refuses to
 * remove the account's only sign-in method — that would lock the user out.
 * Caller should pass a fresh provider count (or rely on the live read here).
 */
export async function unlinkProvider(providerId: string): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');
  if ((user.providerData ?? []).length <= 1) {
    throw new Error(LAST_PROVIDER_ERROR);
  }
  await fbUnlink(user, providerId);
}

// ─── Danger zone: delete account (Phase 5b-iii) ───────────────────────────────

/**
 * Permanently delete the account + all of its data. Mirrors iOS `deleteAccount`.
 *
 * Ordering is load-bearing: delete the Firebase Auth user FIRST. That's the only
 * step that can fail for auth reasons (`requires-recent-login` → the caller
 * reauthenticates and retries), and if it fails nothing has been purged, so the
 * account is left cleanly intact. Deleting the Auth user fires the
 * `onUserDeleted` Cloud Function, which recursively purges this user's Firestore
 * data server-side (the only way to remove the parent `users/{uid}` doc — client
 * rules forbid it). We do NOT call the `deleteUserData` callable: the trigger
 * covers web too, and callable-first would risk purging Firestore and then
 * leaving a live account if `delete()` failed.
 *
 * After the Auth user is gone we wipe every local Dexie table (sync queue
 * included, so nothing re-pushes and resurrects the just-purged Firestore data).
 * The Firebase auth-state listener then nils the session → the app shows the
 * signed-out home. Requires recent login (caller reauthenticates first).
 */
export async function deleteAccount(): Promise<void> {
  const user = auth.currentUser;
  if (!user) throw new Error('No signed-in user');

  // 1. Delete the Auth user (→ server-side onUserDeleted purges Firestore).
  await user.delete();

  // 2. Wipe all device-local data. Clearing every table (vs db.delete()) keeps
  //    the Dexie connection open and is FK-free under IndexedDB, so order
  //    doesn't matter. The sync queue is one of the tables — cleared too.
  await Promise.all(db.tables.map((table) => table.clear()));
}
