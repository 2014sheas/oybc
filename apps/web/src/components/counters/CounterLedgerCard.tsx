import { Link } from 'react-router-dom';
import type { SharedCounterGroup, SharedCounterMemberTask } from '@oybc/shared';
import { Timeframe } from '@oybc/shared';
import styles from './CounterLedgerCard.module.css';

/** Returns the timeframe accent-dot background color for shared-counter rows. */
function timeframeDotColor(tf: Timeframe | null): string {
  switch (tf) {
    case Timeframe.DAILY:      return 'var(--riso-gold)';
    case Timeframe.WEEKLY:     return 'var(--riso-blue)';
    case Timeframe.MONTHLY:    return 'var(--riso-green)';
    case Timeframe.YEARLY:     return 'var(--riso-red)';
    default:                   return 'var(--riso-muted)';
  }
}

interface CounterLedgerCardProps {
  /** The shared counter group to render. */
  group: SharedCounterGroup;
}

/**
 * CounterLedgerCard — one card in the Counters Hub Ledger layout.
 *
 * Layout:
 *   Top row:  counter name + unit tag (left) | big blue lifetime + "all-time {unit}" (right)
 *   Rows:     one row per ACTIVE member task (dot + board · window, logged/goal, progress bar)
 *   Footer:   dashed divider · "Shared by N tasks · N boards" · "Open ›"
 *
 * Matches the `cn-led` design from the shared-counters handoff.
 * The "Open ›" link navigates to `/profile/counters/:counterId`.
 */
export function CounterLedgerCard({ group }: CounterLedgerCardProps): React.ReactElement {
  const activeTasks = group.tasks.filter((t) => t.isActive);
  const lifetimeStr = group.lifetime.toLocaleString();
  const taskCountStr = `${group.activeTaskCount} task${group.activeTaskCount !== 1 ? 's' : ''}`;
  const boardCountStr = `${group.boardCount} board${group.boardCount !== 1 ? 's' : ''}`;

  return (
    <div className={styles.card}>
      {/* Top row: name + lifetime */}
      <div className={styles.top}>
        <div className={styles.nameRow}>
          <span className={styles.name}>{group.name}</span>
          {group.unit && (
            <span className={styles.unitTag} aria-label={`unit: ${group.unit}`}>
              {group.unit}
            </span>
          )}
        </div>
        <div className={styles.lifetimeBlock} aria-label={`${lifetimeStr} all-time ${group.unit ?? 'total'}`}>
          <span className={styles.lifetimeNum}>{lifetimeStr}</span>
          <span className={styles.lifetimeLabel} aria-hidden="true">
            all-time {group.unit ?? 'total'}
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

      {/* Footer: meta + "Open ›" */}
      <div className={styles.footer}>
        <span className={styles.footerMeta}>
          Shared by {taskCountStr} · {boardCountStr}
        </span>
        <Link
          to={`/profile/counters/${group.counterId}`}
          className={styles.openLink}
          aria-label={`Open ${group.name} counter detail`}
        >
          Open ›
        </Link>
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
