import { useEffect, useRef } from 'react';
import { useAuth } from '../firebase/AuthContext';
import { migrateLegacyLocalStoragePreferences } from './usePreferences';

/**
 * One-shot bootstrap hook that lifts any legacy device-local preference
 * values (`oybc-preferences`, `oybc-theme`) into the authenticated user's
 * synced `preferences` record, then clears the localStorage keys.
 *
 * Mounted once at the app shell level (alongside `useSyncLoop`) rather than
 * inside `usePreferences` itself, because the preferences hook is only
 * rendered by views that need to read the values (e.g. `BoardCreatorPanel`).
 * A user who never opens those views would otherwise never have their
 * legacy settings migrated.
 *
 * Idempotent — the ref guards against re-entry in React strict-mode and
 * across renders within a session; the function is a no-op once the legacy
 * keys are cleared.
 */
export function useLegacyPreferencesMigration(): void {
  const { user } = useAuth();
  const userId = user?.id;
  const migratedFor = useRef<string | null>(null);

  useEffect(() => {
    if (!userId || migratedFor.current === userId) return;
    migratedFor.current = userId;
    void migrateLegacyLocalStoragePreferences(userId);
  }, [userId]);
}
