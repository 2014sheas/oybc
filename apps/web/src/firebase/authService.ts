import {
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut as firebaseSignOut,
  onAuthStateChanged as firebaseOnAuthStateChanged,
  updateProfile,
  GoogleAuthProvider,
  OAuthProvider,
  type User as FirebaseUser,
  type Unsubscribe,
} from 'firebase/auth';
import { auth } from './config';
import { db } from '../db/database';
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

export async function signOut(): Promise<void> {
  // Clear sync queue before signing out to prevent cross-user pollution
  await db.syncQueue.clear();
  await firebaseSignOut(auth);
}

/**
 * Subscribe to auth state changes.
 *
 * Fires immediately with the current state, then on every sign-in/sign-out.
 * When a user is present, their local record is upserted.
 *
 * @param callback - Called with the local User or null
 * @returns Unsubscribe function
 */
export function onAuthStateChanged(
  callback: (user: User | null) => void,
): Unsubscribe {
  return firebaseOnAuthStateChanged(auth, async (firebaseUser) => {
    try {
      if (firebaseUser) {
        const user = await upsertLocalUser(firebaseUser);
        callback(user);
      } else {
        callback(null);
      }
    } catch (err) {
      console.error('Auth state change handler failed:', err);
      callback(null);
    }
  });
}

/**
 * Get the current authenticated user's local record, or null.
 */
export function getCurrentUser(): FirebaseUser | null {
  return auth.currentUser;
}
