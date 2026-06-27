import { useEffect, useState } from 'react';
import { useAuth } from '../firebase/useAuth';
import { fullSync } from '../firebase/syncService';
import { useSyncStatus } from '../hooks/useSyncStatus';
import styles from './SyncStatusIndicator.module.css';

/**
 * Compact sync status indicator for production screens (Profile).
 *
 * Shows a minimal three-state status (Up to date / Syncing… / Offline), the
 * last-synced timestamp, and a "Sync Now" button. Mirrors the iOS minimal
 * sync row (#151): the raw `lastError.message` is intentionally NOT surfaced
 * to users — an internal error string is noise (and a potential info leak),
 * not actionable. Reads from the shared `useSyncStatus()` hook + `navigator.onLine`.
 */
export function SyncStatusIndicator(): React.ReactElement {
  const { lastEventAt } = useSyncStatus();
  const { user } = useAuth();
  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const [isSyncing, setIsSyncing] = useState(false);

  useEffect(() => {
    const handleOnline = () => setIsOnline(true);
    const handleOffline = () => setIsOnline(false);
    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);
    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, []);

  const handleSyncNow = async () => {
    if (!user?.id || isSyncing) return;
    setIsSyncing(true);
    try {
      await fullSync(user.id);
    } finally {
      setIsSyncing(false);
    }
  };

  // Minimal three-state status (mirrors iOS #151): Offline \u2192 Syncing\u2026 \u2192 Up to date.
  const statusText = !isOnline ? 'Offline' : isSyncing ? 'Syncing\u2026' : 'Up to date';
  const dotClass = !isOnline ? styles.dotOffline : isSyncing ? styles.dotSyncing : styles.dotOnline;

  return (
    <>
      <div className={styles.row}>
        <span className={styles.label}>Status</span>
        <span className={styles.badge}>
          <span className={dotClass} aria-hidden="true" />
          {statusText}
        </span>
      </div>

      <div className={styles.row}>
        <span className={styles.label}>Last synced</span>
        <span className={styles.value}>
          {lastEventAt ? lastEventAt.toLocaleTimeString() : 'Syncing\u2026'}
        </span>
      </div>

      <div className={styles.row}>
        <button
          type="button"
          className={styles.syncButton}
          onClick={() => void handleSyncNow()}
          disabled={isSyncing || !isOnline}
        >
          {isSyncing ? 'Syncing\u2026' : 'Sync Now'}
        </button>
      </div>
    </>
  );
}
