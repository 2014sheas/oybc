import { useEffect, useState } from 'react';
import { useAuth } from '../firebase/useAuth';
import { fullSync } from '../firebase/syncService';
import { useSyncStatus } from '../hooks/useSyncStatus';
import styles from './SyncStatusIndicator.module.css';

/**
 * Compact sync status indicator for production screens (Profile).
 *
 * Shows online/offline badge, last-synced timestamp, optional error,
 * and a "Sync Now" button. Reads from the shared `useSyncStatus()` hook
 * and `navigator.onLine`.
 */
export function SyncStatusIndicator(): React.ReactElement {
  const { lastEventAt, lastError } = useSyncStatus();
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

  return (
    <>
      <div className={styles.row}>
        <span className={styles.label}>Status</span>
        <span className={styles.badge}>
          <span
            className={isOnline ? styles.dotOnline : styles.dotOffline}
            aria-hidden="true"
          />
          {isOnline ? 'Online' : 'Offline'}
        </span>
      </div>

      <div className={styles.row}>
        <span className={styles.label}>Last synced</span>
        <span className={styles.value}>
          {lastEventAt ? lastEventAt.toLocaleTimeString() : 'Syncing\u2026'}
        </span>
      </div>

      {lastError && (
        <div className={styles.row}>
          <span className={styles.label}>Last error</span>
          <span className={styles.errorValue}>{lastError.message}</span>
        </div>
      )}

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
