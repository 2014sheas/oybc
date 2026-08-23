import { useEffect, useState, type ReactNode } from 'react';
import type { User } from '@oybc/shared';
import {
  signUp as authSignUp,
  signIn as authSignIn,
  signInWithGoogle as authSignInWithGoogle,
  signInWithApple as authSignInWithApple,
  signInAnonymously as authSignInAnonymously,
  signOut as authSignOut,
  refreshLocalUserFromFirebase,
  onAuthStateChanged,
} from './authService';
import { auth } from './config';
import { AuthContext, type AuthContextValue } from './authContextValue';
import { db } from '../db/internal';

// ─── Test-only auth bypass ────────────────────────────────────────────────────

/**
 * Stable identity for the dev-only bypass user. UUID-shaped so all Zod
 * `.uuid()` validators accept it; chose `b…b` rather than `0…0` so it
 * pops in the IndexedDB inspector and any sync-queue payload that
 * accidentally leaks into a real Firestore project (it can't — see
 * gating below — but defense-in-depth).
 */
const BYPASS_USER_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const BYPASS_USER_EMAIL = 'bypass@oybc.local';
const BYPASS_USER_DISPLAY_NAME = 'Bypass Test User';

/**
 * Returns true when the test-only auth bypass is active. Three checks
 * must ALL pass for the bypass to engage:
 *
 *   1. `import.meta.env.DEV` — Vite production builds dead-strip the
 *      branch entirely; the bypass user can never appear in shipped JS.
 *   2. `typeof window !== 'undefined'` — guards against SSR contexts
 *      that don't have window/sessionStorage.
 *   3. A sessionStorage flag set by Playwright via
 *      `await page.evaluate(() => sessionStorage.setItem('__oybc_test_bypass', '1'))`
 *      OR the URL query param `?__oybc_test_bypass=1` (writes the
 *      sessionStorage flag on first load so the rest of the session
 *      keeps it after React Router drops the param on nav).
 *
 * Why sessionStorage instead of the URL param alone: the param survives
 * React Router's in-app `navigate(path)` calls only when explicitly
 * preserved, which is fragile for tests that exercise navigation. The
 * sessionStorage flag keeps the bypass across tab-internal nav until
 * the tab closes (sessionStorage is per-tab) — naturally cleaning up
 * between Playwright's `browser.newContext()` calls.
 */
function isTestBypassActive(): boolean {
  if (!import.meta.env.DEV) return false;
  if (typeof window === 'undefined') return false;
  // Promote the URL param to sessionStorage on first visit so subsequent
  // in-app navigation (which drops query params by default) keeps the
  // bypass live until the tab closes.
  try {
    const params = new URLSearchParams(window.location.search);
    if (params.get('__oybc_test_bypass') === '1') {
      sessionStorage.setItem('__oybc_test_bypass', '1');
    }
    return sessionStorage.getItem('__oybc_test_bypass') === '1';
  } catch {
    // sessionStorage can throw in private-browsing edge cases —
    // treat as "bypass off" rather than crashing the app.
    return false;
  }
}

/**
 * Idempotently inserts the bypass user into Dexie + returns the row.
 * Tests typically clear IndexedDB between cases (see
 * `e2e/_fixtures/bypass.ts`); this function is the single entry point
 * that re-populates it. The row carries the same shape Firebase auth
 * would produce so downstream consumers (`usePreferences`,
 * `useDrafts`, etc.) treat the bypass user identically to a real one.
 */
async function ensureBypassUserRow(): Promise<User> {
  const existing = await db.users.get(BYPASS_USER_ID);
  if (existing) return existing;
  const now = new Date().toISOString();
  const user: User = {
    id: BYPASS_USER_ID,
    email: BYPASS_USER_EMAIL,
    displayName: BYPASS_USER_DISPLAY_NAME,
    createdAt: now,
    updatedAt: now,
    version: 1,
  };
  // `put` instead of `add` — upsert semantics avoid `ConstraintError`
  // when a previous test left a row that the `get` above didn't see
  // (e.g. a race between Dexie open and the get). Idempotent either way.
  await db.users.put(user);
  return user;
}

// ─── Provider ─────────────────────────────────────────────────────────────────

/**
 * AuthProvider wraps the app and provides auth state + actions via React context.
 *
 * Subscribes to Firebase onAuthStateChanged on mount. While the initial state
 * is resolving, `isLoading` is true and `user` is null.
 *
 * **Test bypass**: in dev builds only, when the `__oybc_test_bypass`
 * sessionStorage flag is set, the provider skips the Firebase
 * subscription entirely and signs in as a fake test user (see
 * `isTestBypassActive` above). This is the mechanism Playwright uses
 * to exercise auth-gated routes without provisioning real Firebase
 * test credentials. Production builds dead-strip the branch.
 *
 * @param props.children - App content to wrap
 */
export function AuthProvider({ children }: { children: ReactNode }): React.ReactElement {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isAnonymous, setIsAnonymous] = useState(false);

  useEffect(() => {
    if (isTestBypassActive()) {
      // Bypass path — synthesize a stable fake user, ensure the Dexie
      // row exists, then mark auth ready. Skip the Firebase subscription
      // entirely; Firebase auth is never initialized in this branch.
      let cancelled = false;
      void (async () => {
        try {
          const bypassUser = await ensureBypassUserRow();
          if (cancelled) return;
          setUser(bypassUser);
          setIsAnonymous(false);
          setIsLoading(false);
        } catch (err) {
          // Surface the failure rather than hanging in isLoading=true.
          // Playwright will see the auth gate's sign-in form and the
          // test will fail with a clearer signal than a 30s timeout.
          console.error('[auth-bypass] failed to bootstrap user row', err);
          setIsLoading(false);
        }
      })();
      return () => {
        cancelled = true;
      };
    }

    const unsubscribe = onAuthStateChanged((authUser, anon) => {
      setUser(authUser);
      setIsAnonymous(anon);
      setIsLoading(false);
    });
    return unsubscribe;
  }, []);

  // Reconcile after a guest→account upgrade: linking mutates auth.currentUser
  // in place without firing onAuthStateChanged, so refresh the local row and
  // clear the anon flag explicitly (docs/GUEST_MODE.md §Upgrade).
  const refreshAfterUpgrade = async (): Promise<void> => {
    const refreshed = await refreshLocalUserFromFirebase();
    if (refreshed) setUser(refreshed);
    setIsAnonymous(auth.currentUser?.isAnonymous ?? false);
  };

  const value: AuthContextValue = {
    user,
    isLoading,
    isAnonymous,
    signUp: authSignUp,
    signIn: authSignIn,
    signInWithGoogle: authSignInWithGoogle,
    signInWithApple: authSignInWithApple,
    signInAnonymously: authSignInAnonymously,
    refreshAfterUpgrade,
    signOut: authSignOut,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

// `useAuth` lives in `./useAuth` so this file only exports components
// (required for Fast Refresh). Consumers should import from there:
//   import { useAuth } from '../firebase/useAuth';
