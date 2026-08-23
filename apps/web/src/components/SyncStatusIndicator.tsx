import { useEffect, useState } from 'react';
import { useAuth } from '../firebase/useAuth';
import { fullSync } from '../firebase/syncService';
import { retryExhaustedSyncItems } from '../db/operations/syncQueue';
import { useSyncStatus } from '../hooks/useSyncStatus';
import { UpgradeModal } from './signedOut/UpgradeModal';
import styles from './SyncStatusIndicator.module.css';

/**
 * Compact sync status indicator for production screens (Profile).
 *
 * Shows a minimal three-state status (Up to date / Syncing… / Offline), the
 * last-synced timestamp, and a "Sync Now" button. Mirrors the iOS minimal
 * sync row (#151): the raw `lastError.message` is intentionally NOT surfaced
 * to users — an internal error string is noise (and a potential info leak),
 * not actionable. Reads from the shared `useSyncStatus()` hook + `navigator.onLine`.
 *
 * **Guest mode** (docs/GUEST_MODE.md §Sync semantics): sync genuinely *runs*
 * for an anonymous user (it's a real uid), it just can't be signed into on
 * another device yet — so this renders "Backed up on this device · Sign in
 * to sync across devices" instead of the three-state row, never "not synced".
 */
export function SyncStatusIndicator(): React.ReactElement {
  const { lastEventAt, exhaustedCount } = useSyncStatus();
  const { user, isAnonymous } = useAuth();
  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const [isSyncing, setIsSyncing] = useState(false);
  const [isRetrying, setIsRetrying] = useState(false);
  const [showUpgradeModal, setShowUpgradeModal] = useState(false);

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

  // Manual recovery for items stuck past the retry cap: reset them to a
  // fresh PENDING state, then kick a full sync for immediate feedback.
  const handleRetryExhausted = async () => {
    if (!user?.id || isRetrying) return;
    setIsRetrying(true);
    try {
      await retryExhaustedSyncItems();
      await fullSync(user.id);
    } finally {
      setIsRetrying(false);
    }
  };

  // Guest mode (docs/GUEST_MODE.md \u00a7Sync semantics) \u2014 sync runs, it just
  // can't reach another device yet. Never say "not synced".
  if (isAnonymous) {
    return (
      <>
        <div className={styles.row}>
          <span className={styles.label}>Status</span>
          <span className={styles.badge}>
            <span className={styles.dotOnline} aria-hidden="true" />
            Backed up on this device
          </span>
        </div>
        <div className={styles.row}>
          <button
            type="button"
            className={styles.syncButton}
            onClick={() => setShowUpgradeModal(true)}
          >
            Sign in to sync across devices
          </button>
        </div>
        {showUpgradeModal && <UpgradeModal onClose={() => setShowUpgradeModal(false)} />}
      </>
    );
  }

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

      {/* Exhausted-item recovery \u2014 only rendered when something is stuck
          past the retry cap. Keeps the three-state row above minimal: no
          count, no error text unless N > 0. Copy is a plain count, never
          the raw error (mirrors iOS SyncSheet / the #151 convention). */}
      {exhaustedCount > 0 && (
        <div className={styles.row}>
          <span className={styles.exhaustedLabel}>
            {exhaustedCount === 1
              ? "1 change couldn\u2019t sync"
              : `${exhaustedCount} changes couldn\u2019t sync`}
          </span>
          <button
            type="button"
            className={styles.retryButton}
            onClick={() => void handleRetryExhausted()}
            disabled={isRetrying || !isOnline}
          >
            {isRetrying ? 'Retrying\u2026' : 'Retry'}
          </button>
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
