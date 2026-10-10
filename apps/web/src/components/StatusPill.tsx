import styles from './StatusPill.module.css';

/** The three states a task pill can show. */
export type StatusPillStatus = 'completed' | 'inProgress' | 'notStarted';

/** Task Detail's labels (the default). */
const DETAIL_LABELS: Record<StatusPillStatus, string> = {
  completed: 'Completed',
  inProgress: 'In progress',
  notStarted: 'Never started',
};

/** The Counter Detail "Counts toward" rows' labels (design handoff §C1). */
export const COUNTS_TOWARD_STATUS_LABELS: Record<StatusPillStatus, string> = {
  completed: 'Done',
  inProgress: 'In progress',
  notStarted: 'Not started',
};

export interface StatusPillProps {
  status: StatusPillStatus;
  /** Label set; defaults to Task Detail's. */
  labels?: Record<StatusPillStatus, string>;
  /** Compact scale for list rows (11px, 3×9 padding). */
  dense?: boolean;
}

const VARIANT: Record<StatusPillStatus, string> = {
  completed: styles.statusCompleted,
  inProgress: styles.statusInProgress,
  notStarted: styles.statusNeverStarted,
};

/**
 * StatusPill — a task's state as a keylined pill: completed (green / on-color),
 * in progress (gold / static ink), not started (paper-2 / muted). Shared by
 * Task Detail and Counter Detail's "Counts toward" rows.
 */
export function StatusPill({ status, labels = DETAIL_LABELS, dense }: StatusPillProps): React.ReactElement {
  return <span className={`${styles.statusPill} ${VARIANT[status]} ${dense ? styles.dense : ''}`}>{labels[status]}</span>;
}
