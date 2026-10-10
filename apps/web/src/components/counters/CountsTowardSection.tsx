import type { ContributorRow, ContributorRowStatus } from '@oybc/shared';
import type { CountsTowardSectionData } from '../../db/operations/countsTowardSection';
import { RisoButton } from '../riso/RisoButton';
import { RisoSectionLabel } from '../riso/RisoSectionLabel';
import { RisoTypeBadge } from '../riso/RisoTypeBadge';
import { COUNTS_TOWARD_STATUS_LABELS, StatusPill, type StatusPillStatus } from '../StatusPill';
import { timeframeDotColor } from './timeframeDotColor';
import styles from './CountsTowardSection.module.css';

export interface CountsTowardSectionProps {
  data: CountsTowardSectionData;
  /** `counterDisplayName(root)` — the empty one-liner names it. */
  counterName: string;
  /** "+ New" — opens the task creator preset to this counter. */
  onNew: () => void;
  /** Row tap → Task Detail. */
  onOpenTask: (taskId: string) => void;
}

const PILL_STATUS: Record<ContributorRowStatus, StatusPillStatus> = {
  done: 'completed',
  inProgress: 'inProgress',
  notStarted: 'notStarted',
};

/** The section heading: "Counts toward · N tasks", or just "Counts toward" when empty. */
export function countsTowardHeading(count: number): string {
  if (count === 0) return 'Counts toward';
  return `Counts toward · ${count} task${count === 1 ? '' : 's'}`;
}

/** The muted "× N" credit count — only a repeating contributor (N ≥ 2) shows one. */
export function creditCountText(row: Pick<ContributorRow, 'creditCount'>): string | null {
  return row.creditCount >= 2 ? `× ${row.creditCount}` : null;
}

/** The muted "+N" amount — only when the increment per completion is not 1. */
export function amountText(row: Pick<ContributorRow, 'amount'>): string | null {
  return row.amount === 1 ? null : `+${row.amount}`;
}

/**
 * Counter Detail's "Counts toward" section (docs/SHARED_COUNTER_SETTINGS.md
 * §3d; design handoff §C1): the tasks that count toward a Discrete counter —
 * type badge · title (done = muted + strikethrough) · primary board with its
 * timeframe dot (none when unplaced) · "× N" credits (N ≥ 2) · "+N" amount
 * (≠ 1) · StatusPill — or the empty one-liner. Shown for Discrete counters only.
 */
export function CountsTowardSection({ data, counterName, onNew, onOpenTask }: CountsTowardSectionProps): React.ReactElement {
  const { rows, taskById, boardById } = data;
  return (
    <section className={styles.section} aria-label="Counts toward">
      <div className={styles.headRow}>
        <RisoSectionLabel>{countsTowardHeading(rows.length)}</RisoSectionLabel>
        <RisoButton kind="neutral" size="small" onClick={onNew}>
          + New
        </RisoButton>
      </div>
      {rows.length === 0 ? (
        <p className={styles.empty}>Nothing counts toward {counterName} yet.</p>
      ) : (
        <ul className={styles.list} role="list" aria-label="Tasks that count toward this counter">
          {rows.map((row) => {
            const task = taskById[row.taskId];
            const board = row.boardId ? boardById[row.boardId] : undefined;
            if (!task) return null;
            const credits = creditCountText(row);
            const amount = amountText(row);
            const done = row.status === 'done';
            return (
              <li key={row.taskId} className={styles.item}>
                <button type="button" className={styles.rowButton} onClick={() => onOpenTask(row.taskId)}>
                  <RisoTypeBadge type={task.type} />
                  <span className={styles.main}>
                    <span className={`${styles.title} ${done ? styles.titleDone : ''}`}>{task.title}</span>
                    {(board || credits) && (
                      <span className={styles.boardLine}>
                        {board && (
                          <>
                            <i className={styles.dot} style={{ background: timeframeDotColor(board.timeframe) }} aria-hidden="true" />
                            <span className={styles.boardName}>{board.name}</span>
                          </>
                        )}
                        {credits && <span className={styles.credits}>{credits}</span>}
                      </span>
                    )}
                  </span>
                  {amount && <span className={styles.amount}>{amount}</span>}
                  <StatusPill status={PILL_STATUS[row.status]} labels={COUNTS_TOWARD_STATUS_LABELS} dense />
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
