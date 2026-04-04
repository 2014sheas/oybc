import { initializeApp } from 'firebase/app';
import { getAuth } from 'firebase/auth';
import { getFirestore } from 'firebase/firestore';

// ─── Firebase Configuration ──────────────────────────────────────────────────

/**
 * Firebase app configuration loaded from Vite environment variables.
 *
 * Values are set in `apps/web/.env.local` (gitignored) and accessed
 * via Vite's `import.meta.env.VITE_*` convention.
 */
const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
  measurementId: import.meta.env.VITE_FIREBASE_MEASUREMENT_ID,
};

// ─── Initialize Firebase ─────────────────────────────────────────────────────

const app = initializeApp(firebaseConfig);

/** Firebase Auth instance — used by authService and AuthContext. */
export const auth = getAuth(app);

/** Firestore instance — used by syncService for cloud persistence. */
export const firestore = getFirestore(app);

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Returns the current authenticated user's UID, or null if not signed in.
 */
export function getCurrentUserId(): string | null {
  return auth.currentUser?.uid ?? null;
}
