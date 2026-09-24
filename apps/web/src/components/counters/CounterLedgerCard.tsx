import { useNavigate } from 'react-router-dom';
import { useState } from 'react';
import type { SharedCounterGroup, SharedCounterMemberTask } from '@oybc/shared';
import { incrementSharedCounter } from '../../db/operations/tasks';
import { timeframeDotColor } from './timeframeDotColor';
import styles from './CounterLedgerCard.module.css';

export interface CounterLoggedEvent {
  counterId: string;
  amount: number;
  unit: string;
}

interface CounterLedgerCardProps {
  /** The shared counter group to render. */
  group: SharedCounterGroup;
  /**
   * Called after a successful "+ Log" tap, so the page can surface the
   * shared Undo toast (`CounterLogToast`). Only one toast lives at the page
   * level — this card never renders its own.
   */
  onLogged: (event: CounterLoggedEvent) => void;
  /**
   * §Member rules (B3, RC9) — the hub's "Show expired tasks" value, carried
   * into the Detail route so the two pages agree. The hub owns the state in
   * its URL (`?showExpired=1`); this just forwards it on the tap.
   */
  showExpired?: boolean;
}

/**
 * CounterLedgerCard — one card in the Counters Hub Ledger layout.
 *
 * Layout (R2 Counters UX refresh — design handoff §Counters Hub):
 *   Top row:  counter name (left) | big blue lifetime + "ALL-TIME" label (right)
 *   Rows:     one row per ACTIVE member task (dot + board · window, logged/goal, progress bar)
 *   Footer:   dashed divider · "N tasks · N boards" · "+ Log" pill (blue) · muted "›" chevron
 *
 * The WHOLE card is tappable → Detail (`/profile/counters/:counterId`), except
 * the "+ Log" pill, which logs the counter's current default amount
 * (`group.defaultLogAmount ?? 1`) in place via `incrementSharedCounter` — one
 * tap, no chip picker (that lives on Detail).
 *
 * The card itself is NOT interactive: the tap target is a transparent
 * `<button>` stretched over the whole card, and "+ Log" is a SIBLING control
 * raised above it. Never nest the pill inside a `role="button"` card — the
 * card's Enter/Space handler would cancel the pill's activation and open
 * Detail instead (2026-09 audit).
 */
export function CounterLedgerCard({
  group,
  onLogged,
  showExpired = false,
}: CounterLedgerCardProps): React.ReactElement {
  const navigate = useNavigate();
  const [isLogging, setIsLogging] = useState(false);
  const activeTasks = group.tasks.filter((t) => t.isActive);
  const lifetimeStr = group.lifetime.toLocaleString();
  const taskCountStr = `${group.activeTaskCount} task${group.activeTaskCount !== 1 ? 's' : ''}`;
  const boardCountStr = `${group.boardCount} board${group.boardCount !== 1 ? 's' : ''}`;
  const logAmount = group.defaultLogAmount ?? 1;

  function openDetail(): void {
    navigate(`/profile/counters/${group.counterId}${showExpired ? '?showExpired=1' : ''}`);
  }

  async function handleLog(): Promise<void> {
    if (isLogging) return;
    setIsLogging(true);
    try {
      await incrementSharedCounter(group.counterId, logAmount);
      onLogged({ counterId: group.counterId, amount: logAmount, unit: group.unit ?? '' });
    } finally {
      setIsLogging(false);
    }
  }

  return (
    <div className={styles.card}>
      {/* The card's tap target: stretched over the whole card, first in tab
          order (as the card itself used to be). */}
      <button
        type="button"
        className={styles.openButton}
        onClick={openDetail}
        aria-label={`Open ${group.name} counter detail`}
      />

      {/* Top row: name + lifetime */}
      <div className={styles.top}>
        <span className={styles.name}>{group.name}</span>
        <div className={styles.lifetimeBlock} aria-label={`${lifetimeStr} all-time ${group.unit ?? 'total'}`}>
          <span className={styles.lifetimeNum}>{lifetimeStr}</span>
          <span className={styles.lifetimeLabel} aria-hidden="true">
            ALL-TIME
          </span>
        </div>
      </div>

      {/* Active member task rows */}
      {activeTasks.length > 0 && (
        <div className={styles.rows} role="list" aria-label={`Tasks sharing ${group.name}`}>
          {activeTasks.map((task) => (
            <LedgerTaskRow key={task.taskId} task={task} unit={group.unit} />
          ))}
        </div>
      )}

      {/* Footer: meta + "+ Log" pill + chevron */}
      <div className={styles.footer}>
        <span className={styles.footerMeta}>
          {taskCountStr} · {boardCountStr}
        </span>
        <button
          type="button"
          className={styles.logPill}
          onClick={() => void handleLog()}
          disabled={isLogging}
          aria-label={`Log ${logAmount} ${group.unit ?? ''} for ${group.name}`}
        >
          + Log
        </button>
        <span className={styles.chevron} aria-hidden="true">
          ›
        </span>
      </div>
    </div>
  );
}

/** One active member task row inside a LedgerCard. */
function LedgerTaskRow({
  task,
  unit,
}: {
  task: SharedCounterMemberTask;
  unit: string | null;
}): React.ReactElement {
  const pct = task.goal > 0 ? Math.min(100, (task.logged / task.goal) * 100) : 0;
  const dotColor = timeframeDotColor(task.timeframe);

  return (
    <div className={styles.row} role="listitem">
      {/* Board + window label (left) */}
      <div className={styles.rowLabel}>
        <span
          className={styles.dot}
          style={{ backgroundColor: dotColor }}
          aria-hidden="true"
        />
        <span className={styles.rowName}>
          {task.boardName ?? '—'}
          {task.window && (
            <span className={styles.rowWindow}> · {task.window}</span>
          )}
        </span>
      </div>

      {/* logged/goal value (right) */}
      <div className={styles.rowVal} aria-label={`${task.logged} of ${task.goal} ${unit ?? ''}`}>
        {task.logged.toLocaleString()}
        <span className={styles.rowGoal}>/{task.goal.toLocaleString()}</span>
      </div>

      {/* Progress bar (spans full width below) */}
      <div className={styles.barWrap}>
        <div
          className={`${styles.barFill} ${task.met ? styles.barFillMet : ''}`}
          style={{ width: `${pct}%` }}
          role="progressbar"
          aria-valuenow={Math.round(pct)}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuetext={`${task.logged} of ${task.goal}${unit ? ` ${unit}` : ''}`}
        />
      </div>
    </div>
  );
}
