import { useEffect } from 'react';
import { useAuth } from '../firebase/AuthContext';
import { startSyncLoop } from '../firebase/syncService';

/**
 * Starts a background sync loop when the user is authenticated.
 *
 * Automatically cleans up when the user signs out or the component unmounts.
 * Should be called once in the authenticated layout (not in every page).
 */
export function useSyncLoop(): void {
  const { user } = useAuth();

  useEffect(() => {
    if (!user) return;
    const cleanup = startSyncLoop(user.id);
    return cleanup;
  }, [user]);
}
