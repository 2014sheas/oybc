import { useCallback, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Timeframe } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useSharedCounterGroups } from '../hooks/useSharedCounterGroups';
import { incrementSharedCounter } from '../db/operations/tasks';
import { CounterDetailTaskCard } from '../components/counters';
import { timeframeDotColor } from '../components/counters/timeframeDotColor';
import { RisoSectionLabel } from '../components/riso';
import profileStyles from './ProfilePage.module.css';
import styles from './CounterDetailPage.module.css';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Next round-number milestone above a lifetime total (mirrors cnNextMilestone in proto). */
function nextMilestone(n: number): number {
  const steps = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100_000];
  return steps.find((s) => s > n) ?? Math.ceil((n + 1) / 10_000) * 10_000;
}

/** Display label for a timeframe value. */
function timeframeLabel(tf: Timeframe | null): string {
  switch (tf) {
    case Timeframe.DAILY:      return 'Daily';
    case Timeframe.WEEKLY:     return 'Weekly';
    case Timeframe.MONTHLY:    return 'Monthly';
    case Timeframe.YEARLY:     return 'Yearly';
    case Timeframe.CUSTOM:     return 'Custom';
    case Timeframe.INDEFINITE: return 'Ongoing';
    default:                   return 'Board';
  }
}

// ─── CounterDetailPage ────────────────────────────────────────────────────────

/**
 * CounterDetailPage — single shared counter's home.
 *
 * Route: /profile/counters/:counterId
 *
 * Sections (MVP / P1):
 *   1. Hero card — "{action} · {unit}" tag · "Shared counter" label ·
 *      big blue lifetime total · milestone progress bar.
 *   2. Log control (blue filled card) — "Log {name}" / "+1" increment.
 *      Decrement is TODO(P2) — no decrementSharedCounter exists in
 *      db/operations/tasks.ts yet; P1 ships increment-only.
 *   3. Explainer copy (per design handoff §Counter Detail item 3).
 *   4. "Appears on" — one timeframe chip per distinct active timeframe.
 *   5. "Shared by N tasks" — active member cards (tap → board).
 *   6. "Not counting now" — inactive/draft/unplaced members.
 *
 * Deferred (clean seams left in comments):
 *   - P4: 7-day sparkline
 *   - P4: Streak + Best window stat strip
 *   - P4: Recent windows history
 *
 * Mirrors iOS `CounterDetailView.swift`.
 */
export function CounterDetailPage(): React.ReactElement {
  const { counterId } = useParams<{ counterId: string }>();
  const { user } = useAuth();
  const groups = useSharedCounterGroups(user?.id);
  const [isLogging, setIsLogging] = useState(false);

  const group = groups.find((g) => g.counterId === counterId);

  const handleIncrement = useCallback(async () => {
    if (!counterId || isLogging) return;
    setIsLogging(true);
    try {
      await incrementSharedCounter(counterId);
    } finally {
      setIsLogging(false);
    }
  }, [counterId, isLogging]);

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
          <Link to="/profile/counters" className={profileStyles.backLink} aria-label="Back to Shared counters">
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
  const lifetimeStr = group.lifetime.toLocaleString();
  const unitStr = group.unit ?? '';
  const actionStr = group.action ?? 'Log';

  // Milestone bar
  const nextMs = nextMilestone(group.lifetime);
  const msPct = group.lifetime > 0
    ? Math.min(100, Math.round((group.lifetime / nextMs) * 100))
    : 0;
  const toNextMs = nextMs - group.lifetime;

  // Distinct active timeframes (for "Appears on" chips)
  const activeTimeframes = [
    ...new Set(
      activeTasks
        .map((t) => t.timeframe)
        .filter((tf): tf is Timeframe => tf !== null)
    ),
  ];

  // ─── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Sub-page header */}
      <div className={profileStyles.subPageHeader}>
        <Link
          to="/profile/counters"
          className={profileStyles.backLink}
          aria-label="Back to Shared counters"
        >
          &larr;
        </Link>
        <div>
          <div className={styles.kicker}>PROFILE</div>
          <h1 className={profileStyles.header}>{group.name}</h1>
        </div>
      </div>

      {/* 1. Hero card */}
      <div className={styles.heroCard} aria-label={`${group.name}: ${lifetimeStr} all-time ${unitStr}`}>
        <div className={styles.heroTop}>
          <span className={styles.actionTag} aria-label={`${actionStr} · ${unitStr}`}>
            {actionStr} · {unitStr}
          </span>
          <span className={styles.sharedLabel}>Shared counter</span>
        </div>

        <div className={styles.heroLife}>
          <span className={styles.lifetimeNum}>{lifetimeStr}</span>
          <span className={styles.lifetimeLabel}>all-time {unitStr}</span>
        </div>

        {/* Milestone progress bar */}
        {group.lifetime < nextMs && (
          <div className={styles.milestone} aria-label={`${toNextMs.toLocaleString()} ${unitStr} to ${nextMs.toLocaleString()}`}>
            <div className={styles.milestoneBar} aria-hidden="true">
              <div
                className={styles.milestoneFill}
                style={{ width: `${msPct}%` }}
              />
            </div>
            <p className={styles.milestoneLabel} aria-hidden="true">
              {toNextMs.toLocaleString()} {unitStr} to{' '}
              <strong>{nextMs.toLocaleString()}</strong>
            </p>
          </div>
        )}

        {/* P4: 7-day sparkline */}
        {/* P4: sparkline — needs per-day increment log; deferred to P4 data storage */}
      </div>

      {/* P4: Streak + Best window stat strip */}
      {/* P4: cd-stats strip — needs counter-level streak / best-window history; deferred to P4 */}

      {/* 2. Log control — blue filled card */}
      <div
        className={styles.logCard}
        aria-label={`Log ${group.name}`}
      >
        <div className={styles.logLabel}>
          <span className={styles.logTitle}>Log {group.name}</span>
          <span className={styles.logSub}>
            Counts on all {activeTasks.length} active task{activeTasks.length !== 1 ? 's' : ''}
          </span>
        </div>

        <div className={styles.logStepper} role="group" aria-label={`${group.name} log stepper`}>
          {/* TODO(P2): source decrement — enable once decrementSharedCounter is added to
              db/operations/tasks.ts. The decrement path must clamp to the acting window's
              logged value, apply the effective delta to lifetime + all active windows, and
              be a no-op when all windows are at 0. See docs/SHARED_COUNTERS.md §The engine. */}
          <button
            type="button"
            className={styles.stepperBtn}
            disabled
            aria-label={`Decrease (available in a future update)`}
            aria-disabled="true"
          >
            −
          </button>

          <span className={styles.stepperAmt} aria-hidden="true">+1</span>

          <button
            type="button"
            className={styles.stepperBtn}
            onClick={() => void handleIncrement()}
            disabled={isLogging}
            aria-label={`Add 1 ${unitStr}`}
          >
            +
          </button>
        </div>
      </div>

      {/* 3. Explainer copy */}
      <p className={styles.explainer}>
        Every {unitStr.replace(/s$/, '') || 'rep'} you log lands in each active task's window{' '}
        <strong>and your all-time total</strong> at once — each window keeps its own start and finish,
        so a fresh weekly task can start at 0 while your all-time keeps climbing.
      </p>

      {/* 4. "Appears on" timeframe chips */}
      {activeTimeframes.length > 0 && (
        <>
          <RisoSectionLabel>Appears on</RisoSectionLabel>
          <div className={styles.chips} role="list" aria-label="Timeframes this counter appears on">
            {activeTimeframes.map((tf) => (
              <span
                key={tf}
                className={styles.chip}
                role="listitem"
              >
                <span
                  className={styles.chipDot}
                  style={{ backgroundColor: timeframeDotColor(tf) }}
                  aria-hidden="true"
                />
                {timeframeLabel(tf)}
              </span>
            ))}
          </div>
        </>
      )}

      {/* 5. "Shared by N tasks" — active member cards */}
      {activeTasks.length > 0 && (
        <>
          <RisoSectionLabel>
            Shared by {activeTasks.length} task{activeTasks.length !== 1 ? 's' : ''}
          </RisoSectionLabel>
          <div role="list" aria-label="Active tasks sharing this counter">
            {activeTasks.map((task) => (
              <div key={task.taskId} role="listitem">
                <CounterDetailTaskCard task={task} unit={group.unit} />
              </div>
            ))}
          </div>
        </>
      )}

      {/* P4: Recent windows history */}
      {/* P4: cd-hist section — needs closed-window log; deferred to P4 data storage */}

      {/* 6. "Not counting now" — inactive / draft / unplaced tasks */}
      {inactiveTasks.length > 0 && (
        <>
          <RisoSectionLabel>Not counting now</RisoSectionLabel>
          <div role="list" aria-label="Inactive tasks not currently counting">
            {inactiveTasks.map((task) => (
              <div key={task.taskId} role="listitem">
                <CounterDetailTaskCard task={task} unit={group.unit} inactive />
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
