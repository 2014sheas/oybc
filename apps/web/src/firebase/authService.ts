import {
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  signInWithPopup,
  signInAnonymously as firebaseSignInAnonymously,
  sendPasswordResetEmail,
  signOut as firebaseSignOut,
  onAuthStateChanged as firebaseOnAuthStateChanged,
  updateProfile,
  GoogleAuthProvider,
  OAuthProvider,
  type User as FirebaseUser,
  type Unsubscribe,
} from 'firebase/auth';
import { auth } from './config';
import { db } from '../db/internal';
import { updateUserDisplayName } from '../db/operations/users';
import { DEFAULT_USER_PREFERENCES, mergeUserPreferences, type User } from '@oybc/shared';

// ─── Providers ────────────────────────────────────────────────────────────────

const googleProvider = new GoogleAuthProvider();
const appleProvider = new OAuthProvider('apple.com');
appleProvider.addScope('email');
appleProvider.addScope('name');

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Maps a Firebase Auth user to the local User model and upserts it in Dexie.
 *
 * Called after every successful authentication to keep the local user record
 * in sync with Firebase Auth profile data.
 *
 * @param firebaseUser - The authenticated Firebase user
 * @returns The local User record
 */
async function upsertLocalUser(firebaseUser: FirebaseUser): Promise<User> {
  const now = new Date().toISOString();
  const existing = await db.users.get(firebaseUser.uid);

  // Seed defaults on first sign-in; preserve any existing synced preferences
  // on subsequent sign-ins (mergeUserPreferences fills in missing fields).
  const preferences = existing?.preferences
    ? mergeUserPreferences(existing.preferences)
    : { ...DEFAULT_USER_PREFERENCES };

  const user: User = {
    id: firebaseUser.uid,
    email: firebaseUser.email ?? '',
    displayName: firebaseUser.displayName ?? undefined,
    photoURL: firebaseUser.photoURL ?? undefined,
    preferences,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    lastSyncedAt: existing?.lastSyncedAt,
    version: (existing?.version ?? 0) + 1,
  };

  await db.users.put(user);
  return user;
}

// ─── Auth Operations ──────────────────────────────────────────────────────────

/**
 * Create a new account with email and password.
 *
 * @param email - User's email address
 * @param password - Password (min 6 characters, enforced by Firebase)
 * @returns The local User record
 */
export async function signUp(email: string, password: string): Promise<User> {
  const credential = await createUserWithEmailAndPassword(auth, email, password);
  return upsertLocalUser(credential.user);
}

/**
 * Sign in with email and password.
 *
 * @param email - User's email address
 * @param password - User's password
 * @returns The local User record
 */
export async function signIn(email: string, password: string): Promise<User> {
  const credential = await signInWithEmailAndPassword(auth, email, password);
  return upsertLocalUser(credential.user);
}

/**
 * True when a `sendPasswordResetEmail` failure must still read as "sent":
 * `auth/user-not-found`, which would otherwise reveal that no account uses the
 * address. (With Firebase email-enumeration protection on, the server never
 * returns it; this keeps the form safe when it is off.) Mirrors iOS
 * `PasswordReset.countsAsSent`.
 *
 * @param error - The error `sendPasswordResetEmail` rejected with
 * @returns True when the caller should report success
 */
export function resetErrorCountsAsSent(error: unknown): boolean {
  return (error as { code?: string } | undefined)?.code === 'auth/user-not-found';
}

/**
 * The status line the sign-in form shows after a reset send, e.g.
 * "Reset link sent to alex@example.com". Mirrors iOS `PasswordReset.sentStatus`.
 *
 * @param email - The trimmed address the reset went to
 * @returns The one-line confirmation
 */
export function passwordResetSentStatus(email: string): string {
  return `Reset link sent to ${email}`;
}

/**
 * Send a password-reset email from the signed-out sign-in form's
 * "Forgot password?" action. Enumeration-safe: `auth/user-not-found` resolves
 * exactly like a real send, so the confirmation never reveals whether an
 * account uses the address. Mirrors iOS `AuthService.sendPasswordReset(toEmail:)`.
 *
 * @param email - The email field's value (trimmed here)
 * @returns The trimmed address the reset was sent to
 * @throws The Firebase error for any other failure (e.g. `auth/invalid-email`,
 *   `auth/network-request-failed`) — the form shows it like any auth error
 */
export async function sendPasswordReset(email: string): Promise<string> {
  const normalized = email.trim();
  try {
    await sendPasswordResetEmail(auth, normalized);
  } catch (err) {
    if (!resetErrorCountsAsSent(err)) throw err;
  }
  return normalized;
}

/**
 * Sign in with Google via popup.
 *
 * @returns The local User record
 */
export async function signInWithGoogle(): Promise<User> {
  const credential = await signInWithPopup(auth, googleProvider);
  return upsertLocalUser(credential.user);
}

/**
 * Sign in with Apple via popup.
 *
 * Required by App Store guidelines when Google sign-in is offered.
 *
 * @returns The local User record
 */
export async function signInWithApple(): Promise<User> {
  const credential = await signInWithPopup(auth, appleProvider);
  return upsertLocalUser(credential.user);
}

/**
 * Sign in as a guest via Firebase anonymous auth (docs/GUEST_MODE.md).
 *
 * Mints a real (hidden) anonymous uid so the whole `userId`-keyed app works
 * unchanged and sync runs to the anon-owned tree. Upgrading later = linking a
 * provider, which preserves this uid (no data re-keying). Requires one network
 * round-trip to mint the account; after that the session persists locally and
 * the app is fully offline-first. The anon row has `email: ''` / no displayName.
 *
 * @returns The local User record
 */
export async function signInAnonymously(): Promise<User> {
  const credential = await firebaseSignInAnonymously(auth);
  return upsertLocalUser(credential.user);
}

/**
 * True when an auth error is Firebase's network-request-failed — the one
 * dented offline-first promise of guest mode (docs/GUEST_MODE.md §The one
 * offline-first exception). Minting the anonymous uid needs one network
 * round-trip; callers use this to show honest "you're offline" copy instead
 * of a generic error or a silent half-created guest.
 */
export function isOfflineError(error: unknown): boolean {
  return (error as { code?: string } | undefined)?.code === 'auth/network-request-failed';
}

/** Sign-in surface copy, keyed by Firebase auth error code. A wrong password
 *  and an unknown address read the same (no account enumeration); the shared
 *  lines mirror `friendlyError` in `accountSecurity.ts`. */
const SIGN_IN_ERROR_MESSAGES: Readonly<Record<string, string>> = {
  'auth/invalid-credential': 'Incorrect email or password.',
  'auth/invalid-login-credentials': 'Incorrect email or password.',
  'auth/wrong-password': 'Incorrect email or password.',
  'auth/user-not-found': 'Incorrect email or password.',
  'auth/invalid-email': 'That email address looks invalid.',
  'auth/email-already-in-use': 'That email is already in use by another account.',
  'auth/weak-password': 'Pick a stronger password (at least 6 characters).',
  'auth/too-many-requests': 'Too many attempts. Try again later.',
  'auth/user-disabled': 'This account has been disabled.',
  'auth/network-request-failed': 'You’re offline. Connect and try again.',
  'auth/popup-blocked':
    'Your browser blocked the sign-in popup — allow popups for this site, then try again.',
};

/** Codes for a popup the user closed themselves — nothing to report. */
const SIGN_IN_CANCELLED_CODES = new Set([
  'auth/popup-closed-by-user',
  'auth/cancelled-popup-request',
  'auth/user-cancelled',
]);

/**
 * User-facing copy for an error on the signed-out sign-in form — never
 * Firebase's raw message. Mirrors iOS `SignInErrorMessage.message(for:)`.
 *
 * @param error - The error a sign-in / sign-up / reset / popup call threw
 * @returns The message to show, or null when the user closed the provider
 *   popup themselves (a cancellation shows nothing)
 */
export function signInErrorMessage(error: unknown): string | null {
  const code = (error as { code?: string } | undefined)?.code;
  if (code && SIGN_IN_CANCELLED_CODES.has(code)) return null;
  return (code && SIGN_IN_ERROR_MESSAGES[code]) || 'Something went wrong. Please try again.';
}

/**
 * Re-run the local-user upsert from the current Firebase user (docs/GUEST_MODE.md
 * §Upgrade). Account linking (`link*`) mutates `auth.currentUser` in place and
 * does NOT fire `onAuthStateChanged`, so after a guest→account upgrade the local
 * row would keep `email: ''` / no name unless we reconcile explicitly. Callers
 * invoke this immediately after a successful link. No-op if signed out.
 *
 * @returns The refreshed local User record, or null if no current Firebase user.
 */
export async function refreshLocalUserFromFirebase(): Promise<User | null> {
  const firebaseUser = auth.currentUser;
  if (!firebaseUser) return null;
  return upsertLocalUser(firebaseUser);
}

/** Local state a guest→account upgrade must reconcile (see `reconcileAfterUpgrade`). */
export interface UpgradeReconcileResult {
  /** The re-upserted local User row, or null if signed out. */
  user: User | null;
  /** The session's anon flag, recomputed from the (now linked) Firebase user. */
  isAnonymous: boolean;
}

/**
 * Post-link reconcile (docs/GUEST_MODE.md §Upgrade): re-upsert the local user
 * row from the linked Firebase user AND recompute the session anon flag —
 * linking fires no `onAuthStateChanged`, so neither happens on its own.
 * `AuthContext.refreshAfterUpgrade` applies the result to React state; kept
 * here (not inline in the provider) so it's unit-testable without React.
 *
 * @returns The refreshed row (null if signed out) and the recomputed anon flag
 */
export async function reconcileAfterUpgrade(): Promise<UpgradeReconcileResult> {
  const user = await refreshLocalUserFromFirebase();
  return { user, isAnonymous: auth.currentUser?.isAnonymous ?? false };
}

/**
 * Sign out the current user.
 *
 * Clears the sync queue to prevent cross-user data leakage if another
 * user signs in on the same device.
 */
/**
 * Update the user's display name in Firebase Auth and the local DB.
 *
 * @param newName - New display name; empty/whitespace-only clears it
 */
export async function updateDisplayName(newName: string): Promise<void> {
  const firebaseUser = auth.currentUser;
  if (!firebaseUser) return;

  const trimmed = newName.trim();

  // 1. Update Firebase Auth profile so the name persists on re-auth.
  // Firebase wants `null` to clear, not undefined or empty string.
  await updateProfile(firebaseUser, { displayName: trimmed || null });

  // 2. Update local Dexie User row + enqueue sync.
  // Use empty string (not undefined) for "cleared" — Firestore silently
  // drops undefined fields during writes, so the old value persists and
  // the onSnapshot listener overwrites the local clear. An explicit ''
  // is stored by both IndexedDB and Firestore.
  await updateUserDisplayName(firebaseUser.uid, trimmed);
}

/** User-facing copy when the pre-sign-out queue clear fails (mirrors iOS `AuthServiceError.syncQueueClearFailed`). */
export const SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE =
  "Couldn't sign out safely — local changes couldn't be cleared. Try again.";

/**
 * Sign out the current user and clear the sync queue.
 *
 * The queue is cleared FIRST; if that fails, sign-out is aborted (the user
 * stays signed in) — a leftover queue would push this user's pending writes
 * under the next account that signs in on this device.
 *
 * @throws Error with `SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE` if the queue clear
 *   fails, or the Firebase error if sign-out itself fails.
 */
export async function signOut(): Promise<void> {
  // Clear sync queue before signing out to prevent cross-user pollution
  const cleared = await db.syncQueue.clear().then(
    () => true,
    (err: unknown) => {
      console.error('[authService] signOut: sync-queue clear failed, aborting sign-out', err);
      return false;
    }
  );
  if (!cleared) throw new Error(SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE);
  await firebaseSignOut(auth);
}

/**
 * Subscribe to auth state changes.
 *
 * Fires immediately with the current state, then on every sign-in/sign-out.
 * When a user is present, their local record is upserted.
 *
 * The second callback arg is the Firebase session's `isAnonymous` (guest mode,
 * docs/GUEST_MODE.md) — session-derived, never persisted to the shared User type.
 * Note: account linking does NOT fire this listener, so consumers must also flip
 * their guest state after an upgrade (see `refreshLocalUserFromFirebase`).
 *
 * @param callback - Called with the local User (or null) and the anon flag
 * @returns Unsubscribe function
 */
export function onAuthStateChanged(
  callback: (user: User | null, isAnonymous: boolean) => void,
): Unsubscribe {
  return firebaseOnAuthStateChanged(auth, async (firebaseUser) => {
    try {
      if (firebaseUser) {
        const user = await upsertLocalUser(firebaseUser);
        callback(user, firebaseUser.isAnonymous);
      } else {
        callback(null, false);
      }
    } catch (err) {
      console.error('Auth state change handler failed:', err);
      callback(null, false);
    }
  });
}
