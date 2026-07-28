import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import { useSharedCounterGroups } from '../hooks/useSharedCounterGroups';
import { useTasks } from '../hooks/useTasks';
import {
  CounterLedgerCard,
  CounterLogToast,
  CreateCounterSheet,
  type CounterLoggedEvent,
} from '../components/counters';
import { undoLastCounterLog } from '../db/operations/tasks';
import { generateUUID } from '../db/utils';
import { RisoButton } from '../components/riso';
import profileStyles from './ProfilePage.module.css';
import styles from './CountersHubPage.module.css';

/**
 * CountersHubPage — Counters Hub (Profile → Counters).
 *
 * Route: /profile/counters
 *
 * Displays one Ledger card per shared counter — a card showing the counter's
 * lifetime total and a row per active member task (board · window, logged/goal,
 * progress bar), plus a one-tap "+ Log" pill that logs the counter's default
 * amount. Mirrors iOS `CountersHubView.swift`.
 *
 * R2 Counters UX refresh (design handoff §Counters Hub):
 *   - "+ New counter" header button hides entirely when the list is empty
 *     (the empty state's own CTA is the only entry point then).
 *   - Whole ledger card is tappable → Detail; the "+ Log" pill logs in place
 *     and surfaces the shared `CounterLogToast` ("Logged +N · Undo") — only
 *     one toast lives at this page level at a time.
 *   - Live via `useSharedCounterGroups` (reactive Dexie query).
 */
export function CountersHubPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const groups = useSharedCounterGroups(user?.id);
  const tasks = useTasks(user?.id) ?? [];
  const [sheetOpen, setSheetOpen] = useState(false);
  // `toastKey` is generated ONCE per log (not per render) so CounterLogToast's
  // auto-dismiss timer doesn't restart on unrelated re-renders (e.g. the live
  // `groups` query updating after the log writes).
  const [toast, setToast] = useState<(CounterLoggedEvent & { toastKey: string }) | null>(null);

  function handleCreated(counterId: string): void {
    setSheetOpen(false);
    navigate(`/profile/counters/${counterId}`);
  }

  function handleLogged(event: CounterLoggedEvent): void {
    setToast({ ...event, toastKey: generateUUID() });
  }

  async function handleUndo(): Promise<void> {
    if (!toast) return;
    await undoLastCounterLog(toast.counterId);
    setToast(null);
  }

  return (
    <div className={styles.container}>
      {/* Sub-page header — "+ New counter" hides when the list is empty. */}
      <div className={styles.headerRow}>
        <div className={profileStyles.subPageHeader}>
          <Link to="/profile" className={profileStyles.backLink} aria-label="Back to Profile">
            &larr;
          </Link>
          <div>
            <div className={styles.kicker}>PROFILE</div>
            <h1 className={profileStyles.header}>Counters</h1>
          </div>
        </div>
        {groups.length > 0 && (
          <RisoButton kind="blue" size="small" onClick={() => setSheetOpen(true)}>
            New counter
          </RisoButton>
        )}
      </div>

      {/* Intro (one line) */}
      <p className={profileStyles.subPageIntro}>
        One tally per activity — every task counting it moves together.
      </p>

      {/* Counter cards — Ledger layout */}
      {groups.length === 0 ? (
        <EmptyState onNewCounter={() => setSheetOpen(true)} />
      ) : (
        <div className={styles.cards} role="list" aria-label="Shared counters">
          {groups.map((group) => (
            <div key={group.counterId} role="listitem">
              <CounterLedgerCard group={group} onLogged={handleLogged} />
            </div>
          ))}
        </div>
      )}

      {user?.id && (
        <CreateCounterSheet
          open={sheetOpen}
          onClose={() => setSheetOpen(false)}
          tasks={tasks}
          userId={user.id}
          onCreated={handleCreated}
        />
      )}

      {toast && (
        <CounterLogToast
          key={toast.toastKey}
          amount={toast.amount}
          unit={toast.unit}
          verb="logged"
          onUndo={() => void handleUndo()}
          onDone={() => setToast(null)}
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
        Track one activity — push-ups, pages, miles — across every board it appears on.
      </p>
      <RisoButton kind="blue" size="small" onClick={onNewCounter}>
        + New counter
      </RisoButton>
    </div>
  );
}
