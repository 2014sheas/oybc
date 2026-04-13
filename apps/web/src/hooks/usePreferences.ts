import { useCallback, useEffect, useRef } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { mergeUserPreferences, type UserPreferences } from '@oybc/shared';
import { db } from '../db/database';
import { updateUserPreferences } from '../db/operations/users';
import { useAuth } from '../firebase/AuthContext';

// ─── Legacy localStorage migration ───────────────────────────────────────────

const LEGACY_PREFS_KEY = 'oybc-preferences';

/**
 * One-shot migration: if the legacy localStorage preferences blob exists,
 * copy its `weekStartDay` into the authenticated user's synced preferences
 * and remove the key. Safe to call repeatedly — the key is removed on first
 * successful migration and the function no-ops thereafter.
 */
async function migrateLegacyLocalStoragePreferences(userId: string): Promise<void> {
  let stored: string | null;
  try {
    stored = localStorage.getItem(LEGACY_PREFS_KEY);
  } catch {
    return; // storage disabled / private mode
  }
  if (!stored) return;

  try {
    const parsed = JSON.parse(stored) as Partial<UserPreferences>;
    if (parsed.weekStartDay === 'monday' || parsed.weekStartDay === 'sunday') {
      await updateUserPreferences(userId, { weekStartDay: parsed.weekStartDay });
    }
  } catch {
    // Invalid JSON — just drop it.
  } finally {
    try {
      localStorage.removeItem(LEGACY_PREFS_KEY);
    } catch {
      /* ignore */
    }
  }
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * React hook for reading and updating the authenticated user's synced
 * preferences.
 *
 * Reads reactively from the local `users` Dexie row via `useLiveQuery`, so
 * preferences updated on another device (and pulled in by a sync loop)
 * propagate into the UI immediately. Writes go through
 * `updateUserPreferences`, which bumps `version` + `updatedAt` and enqueues
 * a sync-queue UPDATE entry inside a transaction.
 *
 * While the user row is loading (or when signed out) the returned value is
 * `DEFAULT_USER_PREFERENCES`, so callers never have to deal with undefined.
 *
 * @returns [preferences, updatePreferences]
 */
export function usePreferences(): [
  UserPreferences,
  (updates: Partial<UserPreferences>) => void,
] {
  const { user } = useAuth();
  const userId = user?.id;

  const liveUser = useLiveQuery(
    () => (userId ? db.users.get(userId) : undefined),
    [userId]
  );

  const prefs = mergeUserPreferences(liveUser?.preferences);

  // Run the legacy localStorage migration once per signed-in user. The
  // ref guards against re-running in React strict-mode double-effects or on
  // subsequent renders within the same session.
  const migratedFor = useRef<string | null>(null);
  useEffect(() => {
    if (!userId || migratedFor.current === userId) return;
    migratedFor.current = userId;
    void migrateLegacyLocalStoragePreferences(userId);
  }, [userId]);

  const update = useCallback(
    (updates: Partial<UserPreferences>) => {
      if (!userId) return;
      void updateUserPreferences(userId, updates);
    },
    [userId]
  );

  return [prefs, update];
}
