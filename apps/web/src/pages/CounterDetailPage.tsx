import { useCallback, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import {
  counterMilestoneProgress,
  countUnitSuffix,
  formatCountTotal,
  formatCountWithUnit,
  type CountKind,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useSharedCounterGroups } from '../hooks/useSharedCounterGroups';
import { useCounterDailyTotals } from '../hooks/useCounterDailyTotals';
import {
  computeTaskDeletionImpact,
  decrementSharedCounter,
  deleteCounterWithUnlink,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
  undoLastCounterLog,
  type TaskDeletionImpact,
} from '../db/operations/tasks';
import { generateUUID } from '../db/utils';
import {
  CounterDeleteConfirmDialog,
  CounterDetailLogCard,
  CounterDetailTaskCard,
  CounterLogToast,
  CounterWriteError,
  attemptCounterWrite,
  COUNTER_NOT_UPDATED_MESSAGE,
} from '../components/counters';
import { RowContextMenu } from '../components/wizard/RowContextMenu';
import { RisoSectionLabel } from '../components/riso';
import profileStyles from './ProfilePage.module.css';
import styles from './CounterDetailPage.module.css';

// ─── CounterDetailPage ────────────────────────────────────────────────────────

/**
 * CounterDetailPage — single shared counter's home.
 *
 * Route: /profile/counters/:counterId
 *
 * Sections (R2 Counters UX refresh — design handoff §Counter Detail):
 *   1. Header — back circle · blue "SHARED COUNTER" kicker · counter name ·
 *      "⋯" overflow (Delete counter…).
 *   2. Hero card — 46px blue all-time total + "all-time {noun}", a REAL
 *      7-day sparkline (`useCounterDailyTotals`), and the milestone bar
 *      (`counterMilestoneProgress` from `@oybc/shared`).
 *   3. Stat strip — Today (REAL) / Streak (STUB) / Best week (STUB).
 *   4. Log card (blue fill) — `CounterDetailLogCard`: fixed chips per kind +
 *      −/+Add. Logging updates the counter's `defaultLogAmount` to the amount
 *      just used and shows the reusable `CounterLogToast` ("Logged +N · Undo").
 *   5. "Counting on N tasks" — active member cards.
 *   8. "Not counting now" — inactive/draft/unplaced members (kept from P1;
 *      not in the mock's example state because its sample counter has none).
 *   9. Delete — quiet red text link (was a filled RisoButton).
 *
 * Desktop (≥900px): 360px sticky left rail (hero + stats + log + explainer)
 * and a right column (task cards 2-up, history, delete link).
 *
 * Mirrors iOS `CounterDetailView.swift`.
 */
export function CounterDetailPage(): React.ReactElement {
  const { counterId } = useParams<{ counterId: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();
  // §Member rules (B3, RC9) — Detail FOLLOWS the hub's expired-member
  // setting, carried in the URL (`?showExpired=1`) by the ledger card that
  // opened it. Detail owns no toggle of its own; the back links preserve the
  // param so the hub keeps the setting on the way back.
  const [searchParams] = useSearchParams();
  const showExpired = searchParams.get('showExpired') === '1';
  const countersHubPath = showExpired ? '/profile/counters?showExpired=1' : '/profile/counters';
  const groups = useSharedCounterGroups(user?.id, { showExpired });
  const dailyTotals = useCounterDailyTotals(counterId);

  const [isLogging, setIsLogging] = useState(false);
  const [toast, setToast] = useState<
    { amount: number; unit: string; kind: CountKind; verb: 'logged' | 'removed'; toastKey: string } | null
  >(null);

  const overflowBtnRef = useRef<HTMLButtonElement>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuPos, setMenuPos] = useState<{ x: number; y: number } | null>(null);

  // Delete-counter (P5 decision 8: deleteCounterWithUnlink) UI state.
  const [deleteImpact, setDeleteImpact] = useState<TaskDeletionImpact | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  // Failed log / undo write (see counterWriteFeedback.ts). Cleared on the
  // next successful write.
  const [logError, setLogError] = useState<string | null>(null);

  const group = groups.find((g) => g.counterId === counterId);

  const handleLog = useCallback(
    async (direction: 'add' | 'remove', selectedAmount: number) => {
      if (!counterId || isLogging || selectedAmount <= 0) return;
      setIsLogging(true);
      try {
        const ok = await attemptCounterWrite(`detail ${direction}`, () =>
          direction === 'add'
            ? incrementSharedCounter(counterId, selectedAmount)
            : // decrementSharedCounter clamps to 0 itself — no additional guard needed.
              decrementSharedCounter(counterId, selectedAmount)
        );
        if (!ok) {
          setLogError(COUNTER_NOT_UPDATED_MESSAGE);
          return;
        }
        setLogError(null);
        // The amount just used becomes the new default (no-op if unchanged).
        // Best-effort: the counter itself already moved, so a failure here is
        // logged but doesn't turn the log into an error.
        await attemptCounterWrite('detail default amount', () =>
          setCounterDefaultLogAmount(counterId, selectedAmount)
        );
        setToast({
          amount: selectedAmount,
          unit: group?.unit ?? '',
          kind: group?.countKind ?? 'discrete',
          verb: direction === 'add' ? 'logged' : 'removed',
          toastKey: generateUUID(),
        });
      } finally {
        setIsLogging(false);
      }
    },
    [counterId, isLogging, group?.unit, group?.countKind],
  );

  const handleUndo = useCallback(async () => {
    if (!counterId) return;
    const ok = await attemptCounterWrite('detail undo', () => undoLastCounterLog(counterId));
    // The toast goes either way; a failed undo is announced, never silent.
    setToast(null);
    setLogError(ok ? null : COUNTER_NOT_UPDATED_MESSAGE);
  }, [counterId]);

  function openOverflowMenu(): void {
    const rect = overflowBtnRef.current?.getBoundingClientRect();
    if (!rect) return;
    setMenuPos({ x: rect.right - 190, y: rect.bottom + 6 });
    setMenuOpen(true);
  }

  const handleDeleteClick = useCallback(async () => {
    if (!counterId) return;
    setDeleteError(null);
    try {
      const impact = await computeTaskDeletionImpact(counterId);
      setDeleteImpact(impact);
    } catch {
      setDeleteError('Failed to delete counter.');
    }
  }, [counterId]);

  const handleConfirmDelete = useCallback(async () => {
    if (!counterId || isDeleting) return;
    setIsDeleting(true);
    setDeleteError(null);
    try {
      await deleteCounterWithUnlink(counterId);
      navigate(countersHubPath);
    } catch {
      setDeleteError('Failed to delete counter.');
      setIsDeleting(false);
      setDeleteImpact(null);
    }
  }, [counterId, countersHubPath, isDeleting, navigate]);

  const handleCancelDelete = useCallback(() => {
    if (isDeleting) return;
    setDeleteImpact(null);
  }, [isDeleting]);

  // ─── Loading / not-found states ───────────────────────────────────────────

  if (!group) {
    // `useSharedCounterGroups` returns [] as the default while Dexie is
    // initializing. When groups is still [] we may still be loading — show
    // a minimal shell to avoid a "not found" flash. Once groups resolves to
    // a non-empty list and this counter is still missing, it's genuine "not found".
    const isLoadingQuery = groups.length === 0;
    return (
      <div className={styles.container}>
        <div className={profileStyles.subPageHeader}>
          <Link to={countersHubPath} className={profileStyles.backLink} aria-label="Back to Counters">
            &larr;
          </Link>
          <h1 className={profileStyles.header}>Counter</h1>
        </div>
        {!isLoadingQuery && (
          <p className={profileStyles.subPageIntro}>Counter not found.</p>
        )}
      </div>
    );
  }

  // ─── Derived values ───────────────────────────────────────────────────────

  const activeTasks = group.tasks.filter((t) => t.isActive);
  const inactiveTasks = group.tasks.filter((t) => !t.isActive);
  const kind = group.countKind;
  const lifetimeStr = formatCountTotal(group.lifetime, kind);
  const unitStr = group.unit ?? '';
  // " mi" / "" — Duration never prints a unit (iOS twin uses countUnitSuffix too).
  const heroUnit = countUnitSuffix(kind, group.unit);

  const progress = counterMilestoneProgress(group.lifetime, kind);
  const maxDaily = Math.max(1, ...dailyTotals.days.map((d) => d.total));

  // ─── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Sub-page header */}
      <div className={styles.headerRow}>
        <div className={profileStyles.subPageHeader}>
          <Link
            to={countersHubPath}
            className={profileStyles.backLink}
            aria-label="Back to Counters"
          >
            &larr;
          </Link>
          <div>
            <div className={styles.kicker}>SHARED COUNTER</div>
            <h1 className={profileStyles.header}>{group.name}</h1>
          </div>
        </div>
        <button
          ref={overflowBtnRef}
          type="button"
          className={styles.overflowBtn}
          aria-label="Counter options"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={openOverflowMenu}
        >
          ⋯
        </button>
        {menuOpen && menuPos && (
          <RowContextMenu
            x={menuPos.x}
            y={menuPos.y}
            items={[
              {
                label: 'Delete counter…',
                glyph: '✕',
                destructive: true,
                action: () => void handleDeleteClick(),
              },
            ]}
            onClose={() => setMenuOpen(false)}
          />
        )}
      </div>

      <div className={styles.layout}>
        {/* Left rail (desktop) / top section (mobile) */}
        <div className={styles.leftRail}>
          {/* 1. Hero card */}
          <div className={styles.heroCard} aria-label={`${group.name}: ${lifetimeStr} all-time${heroUnit}`}>
            <div className={styles.heroTop}>
              <div className={styles.heroLifeBlock}>
                <span
                  className={`${styles.lifetimeNum} ${kind === 'duration' ? styles.lifetimeNumDuration : ''}`}
                >
                  {lifetimeStr}
                </span>
                <span className={styles.lifetimeLabel}>all-time{heroUnit}</span>
              </div>

              {/* 7-day sparkline — REAL data via useCounterDailyTotals. */}
              {dailyTotals.days.length > 0 && (
                <div
                  className={styles.sparkline}
                  role="img"
                  aria-label={`7-day activity — today ${formatCountWithUnit(dailyTotals.todayTotal, kind, unitStr)}`}
                >
                  {dailyTotals.days.map((d, i) => {
                    const isToday = i === dailyTotals.days.length - 1;
                    const heightPct = Math.max(6, Math.round((d.total / maxDaily) * 100));
                    return (
                      <span
                        key={d.dateISO}
                        className={`${styles.sparkBar} ${isToday ? styles.sparkBarToday : ''}`}
                        style={{ height: `${heightPct}%` }}
                        aria-hidden="true"
                      />
                    );
                  })}
                </div>
              )}
            </div>

            {/* Milestone progress bar */}
            <div className={styles.milestone}>
              <div className={styles.milestoneBar} aria-hidden="true">
                <div className={styles.milestoneFill} style={{ width: `${progress.fraction * 100}%` }} />
              </div>
              <p className={styles.milestoneLabel}>
                {formatCountTotal(progress.remaining, kind)} to{' '}
                <strong>{formatCountTotal(progress.next, kind)}</strong> milestone
              </p>
            </div>
          </div>

          {/* 2. Stat strip — Today (real) / Streak / Best week (P4 stubs) */}
          <div className={styles.statStrip}>
            <StatCard label="TODAY" value={formatCountTotal(dailyTotals.todayTotal, kind)} />
            {/* P4 — build-now-feed-P4: needs a real streak rollup (window-goal
                history); UI shipped now, wired to real data in P4. */}
            <StatCard label="STREAK" value="—" />
            {/* P4 — build-now-feed-P4: needs closed-window best-week rollup storage. */}
            <StatCard label="BEST WEEK" value="—" />
          </div>

          {/* 3. Log control — blue filled card */}
          <CounterDetailLogCard
            key={`${group.counterId}-${kind}`}
            kind={kind}
            unit={group.unit}
            defaultLogAmount={group.defaultLogAmount}
            lifetime={group.lifetime}
            isLogging={isLogging}
            onLog={(direction, amount) => void handleLog(direction, amount)}
          />

          <CounterWriteError message={logError} />
        </div>

        {/* Right column (desktop) / bottom section (mobile) */}
        <div className={styles.rightCol}>
          {/* 5. "Counting on N tasks" — active member cards */}
          {activeTasks.length > 0 && (
            <>
              <RisoSectionLabel>
                Counting on {activeTasks.length} task{activeTasks.length !== 1 ? 's' : ''}
              </RisoSectionLabel>
              <div className={styles.taskCardsGrid} role="list" aria-label="Active tasks sharing this counter">
                {activeTasks.map((task) => (
                  <div key={task.taskId} role="listitem">
                    <CounterDetailTaskCard task={task} unit={group.unit} kind={kind} />
                  </div>
                ))}
              </div>
            </>
          )}

          {/* 7. "Not counting now" — inactive / draft / unplaced tasks */}
          {inactiveTasks.length > 0 && (
            <>
              <RisoSectionLabel>Not counting now</RisoSectionLabel>
              <div role="list" aria-label="Inactive tasks not currently counting">
                {inactiveTasks.map((task) => (
                  <div key={task.taskId} role="listitem">
                    <CounterDetailTaskCard task={task} unit={group.unit} kind={kind} inactive />
                  </div>
                ))}
              </div>
            </>
          )}

          {/* 8. Delete-counter action — quiet red text link (was a filled button). */}
          {deleteError && <p className={styles.deleteError}>{deleteError}</p>}
          <div className={styles.deleteAction}>
            <button type="button" className={styles.deleteLink} onClick={() => void handleDeleteClick()}>
              Delete counter…
            </button>
          </div>
        </div>
      </div>

      {deleteImpact && (
        <CounterDeleteConfirmDialog
          counterName={group.name}
          memberCount={deleteImpact.counterMemberCount}
          derivedWindowCounterCount={deleteImpact.derivedWindowCounterCount}
          members={deleteImpact.counterMembers.map((m) => ({
            id: m.id,
            title: m.title,
            boardName:
              group.tasks.find((t) => t.taskId === m.id)?.boardName ?? null,
          }))}
          busy={isDeleting}
          onConfirm={() => void handleConfirmDelete()}
          onCancel={handleCancelDelete}
        />
      )}

      {toast && (
        <CounterLogToast
          key={toast.toastKey}
          amount={toast.amount}
          unit={toast.unit}
          kind={toast.kind}
          verb={toast.verb}
          onUndo={() => void handleUndo()}
          onDone={() => setToast(null)}
        />
      )}
    </div>
  );
}

/** One mini stat card in the stat strip (Today / Streak / Best week). */
function StatCard({ label, value }: { label: string; value: string }): React.ReactElement {
  return (
    <div className={styles.statCard}>
      <span className={styles.statValue}>{value}</span>
      <span className={styles.statLabel}>{label}</span>
    </div>
  );
}
