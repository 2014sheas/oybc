import { useSyncExternalStore } from 'react';
import {
  getSyncStatus,
  subscribeSyncStatus,
  type SyncStatus,
} from '../firebase/syncStatus';

/**
 * React subscription to the sync layer's in-memory observability state.
 *
 * Backed by `useSyncExternalStore` so re-renders only fire when the
 * underlying state object reference actually changes (each
 * `recordSyncEvent` produces a fresh object — no equality fooling).
 */
export function useSyncStatus(): SyncStatus {
  return useSyncExternalStore(subscribeSyncStatus, getSyncStatus, getSyncStatus);
}
