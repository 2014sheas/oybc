import type { Task } from '@oybc/shared';
import styles from './TaskDetailContent.module.css';

export interface LinkedCounterCaptionViewProps {
  /** The linking task's `sharedCounterId` (the counter root's task id). */
  sharedCounterId: string;
  /** True until the root-task lookup has resolved. */
  isLoading: boolean;
  /** The resolved, non-deleted root task; null when not found. */
  sourceTask: Task | null;
  /** Opens Counter detail. When omitted the found state is a plain caption. */
  onOpenCounter?: (sharedCounterId: string) => void;
}

/**
 * Presentational "Linked to {root}" line on a linked counting task's detail.
 * Found + `onOpenCounter` → a full-width row button (title, all-time total,
 * chevron); loading / not-found stay non-interactive captions.
 */
export function LinkedCounterCaptionView({
  sharedCounterId,
  isLoading,
  sourceTask,
  onOpenCounter,
}: LinkedCounterCaptionViewProps): React.ReactElement {
  if (sourceTask && onOpenCounter) {
    return (
      <button
        type="button"
        className={`${styles.subtaskRow} ${styles.linkedCounterRow}`}
        aria-label={`Open ${sourceTask.title} counter`}
        onClick={() => onOpenCounter(sharedCounterId)}
      >
        <span className={styles.linkedCounterLabel}>Linked to</span>
        <span className={styles.linkedCounterTitle}>{sourceTask.title}</span>
        <span className={styles.linkedCounterTotal}>
          {(sourceTask.currentCount ?? 0).toLocaleString()} {sourceTask.unit}
        </span>
        <span className={styles.linkedCounterChevron} aria-hidden="true">›</span>
      </button>
    );
  }
  return (
    <p className={styles.linkedCounterCaption}>
      Linked to{' '}
      {isLoading
        ? <em>loading…</em>
        : sourceTask
          ? <strong>{sourceTask.title}</strong>
          : <em>source task (deleted or not found)</em>}
    </p>
  );
}
