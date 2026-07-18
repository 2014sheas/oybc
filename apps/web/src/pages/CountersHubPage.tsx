import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import { useSharedCounterGroups } from '../hooks/useSharedCounterGroups';
import { useTasks } from '../hooks/useTasks';
import { CounterLedgerCard, CreateCounterSheet } from '../components/counters';
import { RisoButton, RisoSectionLabel } from '../components/riso';
import profileStyles from './ProfilePage.module.css';
import styles from './CountersHubPage.module.css';

/**
 * CountersHubPage — "Shared counters" sub-page (Profile → Shared counters).
 *
 * Route: /profile/counters
 *
 * Displays one Ledger card per shared counter — a card showing the counter's
 * lifetime total and a row per active member task (board · window, logged/goal,
 * progress bar). Mirrors iOS `CountersHubView.swift`.
 *
 * Scope (P1):
 *   - Ledger layout only (Tiles/Meters are prototype alternates — not shipped).
 *   - Live via `useSharedCounterGroups` (reactive Dexie query).
 *   - Empty state when the user has no shared counters.
 *
 * P2/P3 items (not here):
 *   - Board-play shared marker and credited toast.
 *   - Passive completion / arrival banner.
 */
export function CountersHubPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const groups = useSharedCounterGroups(user?.id);
  const tasks = useTasks(user?.id) ?? [];
  const [sheetOpen, setSheetOpen] = useState(false);

  function handleCreated(counterId: string): void {
    setSheetOpen(false);
    navigate(`/profile/counters/${counterId}`);
  }

  return (
    <div className={styles.container}>
      {/* Sub-page header */}
      <div className={styles.headerRow}>
        <div className={profileStyles.subPageHeader}>
          <Link to="/profile" className={profileStyles.backLink} aria-label="Back to Profile">
            &larr;
          </Link>
          <div>
            <div className={styles.kicker}>PROFILE</div>
            <h1 className={profileStyles.header}>Shared counters</h1>
          </div>
        </div>
        <RisoButton kind="blue" size="small" onClick={() => setSheetOpen(true)}>
          + New counter
        </RisoButton>
      </div>

      {/* Intro paragraph */}
      <p className={profileStyles.subPageIntro}>
        One activity, one running tally. Log <strong>push-ups</strong> on any board and every task
        that counts push-ups moves — each keeping its own start and finish.
      </p>

      {/* Counter cards — Ledger layout */}
      {groups.length === 0 ? (
        <EmptyState onNewCounter={() => setSheetOpen(true)} />
      ) : (
        <>
          <RisoSectionLabel>Your counters</RisoSectionLabel>
          <div className={styles.cards} role="list" aria-label="Shared counters">
            {groups.map((group) => (
              <div key={group.counterId} role="listitem">
                <CounterLedgerCard group={group} />
              </div>
            ))}
          </div>
        </>
      )}

      {/* Footer note */}
      <p className={styles.footerNote}>
        Counters are shared automatically — tasks with the same activity and unit link up on their
        own.
      </p>

      {user?.id && (
        <CreateCounterSheet
          open={sheetOpen}
          onClose={() => setSheetOpen(false)}
          tasks={tasks}
          userId={user.id}
          onCreated={handleCreated}
        />
      )}
    </div>
  );
}

function EmptyState({ onNewCounter }: { onNewCounter: () => void }): React.ReactElement {
  return (
    <div className={styles.emptyState} role="status" aria-live="polite">
      <span className={styles.emptyIcon} aria-hidden="true">↔</span>
      <p className={styles.emptyPrimary}>No counters yet</p>
      <p className={styles.emptySub}>
        Create a counter to track one activity across every board — or link a counting task when
        you create one.
      </p>
      <RisoButton kind="blue" size="small" onClick={onNewCounter}>
        + New counter
      </RisoButton>
    </div>
  );
}
