import { useEffect } from 'react';
import { useAuth } from '../firebase/useAuth';
import { startSyncLoop } from '../firebase/syncService';
import { runPlacementSweep } from '../db/operations/placementSweep';

/**
 * Starts a background sync loop when the user is authenticated.
 *
 * Automatically cleans up when the user signs out or the component unmounts.
 * Should be called once in the authenticated layout (not in every page).
 */
export function useSyncLoop(): void {
  const { user } = useAuth();
  const userId = user?.id;

  useEffect(() => {
    if (!userId) return;
    // Migration sweep on every app open (TASK_WINDOW_REWORK slice 4): once per
    // signed-in session, in addition to the post-pull run. Never throws.
    runPlacementSweep(userId).catch((err) => {
      console.error('[placement-sweep] app-open run failed', err);
    });
    const cleanup = startSyncLoop(userId);
    return cleanup;
  }, [userId]);
}
