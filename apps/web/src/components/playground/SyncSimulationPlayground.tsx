import { useState, useCallback } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../../firebase/useAuth';
import { fullSync } from '../../firebase/syncService';
import { clearCompletedSyncItems } from '../../db/operations/syncQueue';
import { db } from '../../db/database';
import { SyncStatus, type SyncQueueItem } from '@oybc/shared';
import { AuthGate } from '../AuthGate';
import { useSyncStatus } from '../../hooks/useSyncStatus';
import styles from './SyncSimulationPlayground.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

interface SyncEvent {
  id: number;
  timestamp: string;
  message: string;
  type: 'push' | 'pull' | 'conflict' | 'error' | 'info';
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * SyncSimulationPlayground demonstrates real Firestore sync:
 * - Shows the local sync queue (pending/completed/failed items)
 * - "Sync Now" button triggers a full push+pull cycle
 * - Event log shows what happened during sync
 * - Requires authentication (wraps content in AuthGate)
 */
export function SyncSimulationPlayground(): React.ReactElement {
  return (
    <AuthGate>
      <SyncDashboard />
    </AuthGate>
  );
}

// ─── Dashboard (authenticated) ───────────────────────────────────────────────

function SyncDashboard(): React.ReactElement {
  const { user } = useAuth();
  const [isSyncing, setIsSyncing] = useState(false);
  const [events, setEvents] = useState<SyncEvent[]>([]);
  const syncStatus = useSyncStatus();

  // ── Reactive sync queue data ──────────────────────────────────────────

  const allQueueItems: SyncQueueItem[] =
    useLiveQuery(() => db.syncQueue.toArray(), [], []) ?? [];

  const pendingCount = allQueueItems.filter(
    (i) => i.status === SyncStatus.PENDING || i.status === SyncStatus.IN_PROGRESS
  ).length;
  const completedCount = allQueueItems.filter(
    (i) => i.status === SyncStatus.COMPLETED
  ).length;
  const failedCount = allQueueItems.filter(
    (i) => i.status === SyncStatus.FAILED
  ).length;

  // ── Helpers ───────────────────────────────────────────────────────────

  const addEvent = useCallback(
    (message: string, type: SyncEvent['type']) => {
      setEvents((evts) => [
        {
          id: Date.now() + Math.random(),
          timestamp: new Date().toLocaleTimeString(),
          message,
          type,
        },
        ...evts,
      ].slice(0, 50));
    },
    []
  );

  // ── Sync handler ──────────────────────────────────────────────────────

  const handleSync = useCallback(async () => {
    if (!user || isSyncing) return;
    setIsSyncing(true);
    addEvent('Starting full sync...', 'info');

    try {
      const result = await fullSync(user.id);

      // Always log the summary
      addEvent(
        `Push: ${result.push.pushed} pushed, ${result.push.conflicts} conflicts, ${result.push.failed} failed`,
        result.push.failed > 0 ? 'error' : 'push'
      );

      // Log each detail
      for (const detail of result.push.details) {
        addEvent(detail, detail.includes('Conflict') ? 'conflict' : detail.includes('Failed') ? 'error' : 'push');
      }

      if (result.pull.pulled > 0 || result.pull.conflicts > 0 || result.pull.details.length > 0) {
        addEvent(
          `Pull: ${result.pull.pulled} pulled, ${result.pull.conflicts} kept local`,
          'pull'
        );
      }
      for (const detail of result.pull.details) {
        addEvent(detail, detail.includes('Kept local') ? 'conflict' : detail.includes('failed') ? 'error' : 'pull');
      }
    } catch (err) {
      addEvent(`Sync failed: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setIsSyncing(false);
    }
  }, [user, isSyncing, addEvent]);

  const handleClearCompleted = useCallback(async () => {
    await clearCompletedSyncItems();
    addEvent('Cleared completed sync items', 'info');
  }, [addEvent]);

  // ── Render ────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* ── Controls ── */}
      <div className={styles.controls}>
        <button
          type="button"
          className={styles.syncButton}
          onClick={() => void handleSync()}
          disabled={isSyncing}
        >
          {isSyncing ? 'Syncing...' : 'Sync Now'}
        </button>
        <button
          type="button"
          className={styles.clearButton}
          onClick={() => void handleClearCompleted()}
          disabled={completedCount === 0}
        >
          Clear Completed ({completedCount})
        </button>
        <span className={styles.onlineStatus}>
          {navigator.onLine ? 'Online' : 'Offline'}
        </span>
      </div>

      {/* ── Queue Summary ── */}
      <div className={styles.queueSummary}>
        <div className={`${styles.summaryItem} ${styles.summaryPending}`}>
          <span className={styles.summaryCount}>{pendingCount}</span>
          <span className={styles.summaryLabel}>Pending</span>
        </div>
        <div className={`${styles.summaryItem} ${styles.summaryCompleted}`}>
          <span className={styles.summaryCount}>{completedCount}</span>
          <span className={styles.summaryLabel}>Completed</span>
        </div>
        <div className={`${styles.summaryItem} ${styles.summaryFailed}`}>
          <span className={styles.summaryCount}>{failedCount}</span>
          <span className={styles.summaryLabel}>Failed</span>
        </div>
        <div className={styles.summaryItem}>
          <span className={styles.summaryCount}>{allQueueItems.length}</span>
          <span className={styles.summaryLabel}>Total</span>
        </div>
      </div>

      {/* ── Session activity (cumulative since app start) ── */}
      <div className={styles.sessionActivity}>
        <div className={styles.sessionHeader}>
          <span className={styles.sessionTitle}>Session activity</span>
          <span className={styles.sessionTimestamp}>
            {syncStatus.lastEventAt
              ? `Last: ${syncStatus.lastEventAt.toLocaleTimeString()}`
              : 'No activity yet'}
          </span>
        </div>
        <div className={styles.queueSummary}>
          <div className={`${styles.summaryItem} ${styles.summaryPushed}`}>
            <span className={styles.summaryCount}>{syncStatus.totalPushed}</span>
            <span className={styles.summaryLabel}>Pushed</span>
          </div>
          <div className={`${styles.summaryItem} ${styles.summaryPulled}`}>
            <span className={styles.summaryCount}>{syncStatus.totalPulled}</span>
            <span className={styles.summaryLabel}>Pulled</span>
          </div>
          <div className={`${styles.summaryItem} ${styles.summaryPending}`}>
            <span className={styles.summaryCount}>{syncStatus.totalConflicts}</span>
            <span className={styles.summaryLabel}>Conflicts</span>
          </div>
          <div className={`${styles.summaryItem} ${styles.summaryFailed}`}>
            <span className={styles.summaryCount}>{syncStatus.totalFailed}</span>
            <span className={styles.summaryLabel}>Failed</span>
          </div>
        </div>
        {syncStatus.lastError && (
          <div className={styles.lastErrorCard}>
            <span className={styles.lastErrorLabel}>⚠ Last error</span>
            <span className={styles.lastErrorMessage}>{syncStatus.lastError.message}</span>
          </div>
        )}
      </div>

      {/* ── Sync Queue Table ── */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Sync Queue</h4>
        {allQueueItems.length === 0 ? (
          <p className={styles.emptyState}>
            No sync queue items. Make changes (create boards, complete tasks) to see items appear here.
          </p>
        ) : (
          <div className={styles.tableWrapper}>
            <table className={styles.table}>
              <thead>
                <tr>
                  <th>Entity</th>
                  <th>Operation</th>
                  <th>Status</th>
                  <th>Retries</th>
                  <th>Created</th>
                </tr>
              </thead>
              <tbody>
                {allQueueItems
                  .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
                  .slice(0, 20)
                  .map((item) => (
                    <tr key={item.id}>
                      <td className={styles.entityCell}>
                        <span className={styles.entityType}>{item.entityType}</span>
                        <span className={styles.entityId}>{item.entityId.slice(0, 8)}...</span>
                      </td>
                      <td>
                        <span className={`${styles.opBadge} ${styles[`op${item.operationType}`]}`}>
                          {item.operationType.toUpperCase()}
                        </span>
                      </td>
                      <td>
                        <span className={`${styles.statusBadge} ${styles[`status${item.status}`]}`}>
                          {item.status}
                        </span>
                      </td>
                      <td className={styles.retryCell}>{item.retryCount}</td>
                      <td className={styles.timeCell}>
                        {new Date(item.createdAt).toLocaleTimeString()}
                      </td>
                    </tr>
                  ))}
              </tbody>
            </table>
            {allQueueItems.length > 20 && (
              <p className={styles.truncated}>
                Showing 20 of {allQueueItems.length} items
              </p>
            )}
          </div>
        )}
      </section>

      {/* ── Event Log ── */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Sync Event Log</h4>
        {events.length === 0 ? (
          <p className={styles.emptyState}>
            Click "Sync Now" to see sync events here.
          </p>
        ) : (
          <div className={styles.eventLog}>
            {events.map((evt) => (
              <div key={evt.id} className={`${styles.eventRow} ${styles[`event${evt.type}`]}`}>
                <span className={styles.eventTime}>{evt.timestamp}</span>
                <span className={styles.eventMessage}>{evt.message}</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
