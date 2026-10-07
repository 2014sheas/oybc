import { countUnitSuffix, formatCountTotal, resolveCountKind, type Task } from '@oybc/shared';
import styles from './TaskDetailContent.module.css';

export interface LinkedCounterCaptionViewProps {
  /** The linking task's `sharedCounterId` (the counter root's task id). */
  sharedCounterId: string;
  /** True until the root-task lookup has resolved (unused: loading renders nothing). */
  isLoading: boolean;
  /** The resolved, non-deleted root task; null when not found. */
  sourceTask: Task | null;
  /** Opens Counter detail. Without it nothing renders. */
  onOpenCounter?: (sharedCounterId: string) => void;
}

/**
 * The linked counting task's row to its counter root on Task Detail: the
 * root's title, its all-time total in the root's kind, and a chevron. Loading
 * and not-found render nothing (#548 rows 91/92 — no provenance caption).
 *
 * @returns The row button, or null while loading / when the root is gone.
 */
export function LinkedCounterCaptionView({
  sharedCounterId,
  sourceTask,
  onOpenCounter,
}: LinkedCounterCaptionViewProps): React.ReactElement | null {
  if (!sourceTask || !onOpenCounter) return null;
  const kind = resolveCountKind(sourceTask);
  return (
    <button
      type="button"
      className={`${styles.subtaskRow} ${styles.linkedCounterRow}`}
      aria-label={`Open ${sourceTask.title} counter`}
      onClick={() => onOpenCounter(sharedCounterId)}
    >
      <span className={styles.linkedCounterTitle}>{sourceTask.title}</span>
      <span className={styles.linkedCounterTotal}>
        {formatCountTotal(sourceTask.currentCount ?? 0, kind)}
        {countUnitSuffix(kind, sourceTask.unit)}
      </span>
      <span className={styles.linkedCounterChevron} aria-hidden="true">›</span>
    </button>
  );
}
