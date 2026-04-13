import { useCallback, useEffect, useRef } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { mergeUserPreferences, type UserPreferences } from '@oybc/shared';
import { db } from '../db/database';
import { updateUserPreferences } from '../db/operations/users';
import { useAuth } from '../firebase/AuthContext';

// ─── Legacy localStorage migration ───────────────────────────────────────────

const LEGACY_PREFS_KEY = 'oybc-preferences';
const LEGACY_THEME_KEY = 'oybc-theme';

function readLocalStorage(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null; // storage disabled / private mode
  }
}

function clearLocalStorage(key: string): void {
  try {
    localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

/**
 * One-shot migration: lifts any legacy device-local preference values
 * (`oybc-preferences` JSON blob, `oybc-theme` scalar) into the authenticated
 * user's synced preferences record, then removes the localStorage keys. Safe
 * to call repeatedly — once the keys are cleared the function no-ops.
 */
async function migrateLegacyLocalStoragePreferences(userId: string): Promise<void> {
  const partial: Partial<UserPreferences> = {};

  const storedPrefs = readLocalStorage(LEGACY_PREFS_KEY);
  if (storedPrefs) {
    try {
      const parsed = JSON.parse(storedPrefs) as Partial<UserPreferences>;
      if (parsed.weekStartDay === 'monday' || parsed.weekStartDay === 'sunday') {
        partial.weekStartDay = parsed.weekStartDay;
      }
    } catch {
      // Invalid JSON — drop it along with the key below.
    }
  }

  const storedTheme = readLocalStorage(LEGACY_THEME_KEY);
  if (storedTheme === 'light' || storedTheme === 'dark' || storedTheme === 'system') {
    partial.theme = storedTheme;
  }

  if (Object.keys(partial).length > 0) {
    await updateUserPreferences(userId, partial);
  }

  // Clear both keys either way — an unrecognised legacy value shouldn't linger.
  if (storedPrefs) clearLocalStorage(LEGACY_PREFS_KEY);
  if (storedTheme) clearLocalStorage(LEGACY_THEME_KEY);
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
