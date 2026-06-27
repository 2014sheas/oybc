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
  reauthenticateWithCredential,
  reauthenticateWithPopup,
  sendPasswordResetEmail,
  updatePassword as fbUpdatePassword,
  verifyBeforeUpdateEmail,
  type AuthError,
} from 'firebase/auth';
import { auth } from './config';
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
  const { db } = await import('../db/database');
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
 * change-email / change-password. (Provider link/unlink for Google/Apple lands
 * in Phase 5b-ii.) Treats "already linked" as an idempotent success.
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
