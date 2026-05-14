import { generateCounterTaskTitle, TaskType, type Task } from '@oybc/shared';
import { TypeBadge } from '../../components/TypeBadge';
import styles from './TaskRow.module.css';

export interface TaskRowProps {
  task: Task;
  /** Pre-computed count of non-deleted `BoardTask` placements. */
  placementCount: number;
  /** Pre-computed count of placements on ACTIVE boards specifically.
   *  Drives the "On N active boards" hint. */
  activePlacementCount: number;
  /** Pre-computed count of compound children (for compound-type tasks).
   *  Skipped for any other type. */
  childCount: number;
  onClick: (taskId: string) => void;
}

/**
 * TaskRow — single list row on the Tasks tab. Title + type badge + a
 * one-line status/usage hint. Tapping the row navigates to the task
 * detail page.
 *
 * Kept deliberately simpler than the wizard's `renderTaskRow` — no
 * selection state, no center-pinning, no right-click "add to board".
 * If a future change needs to consolidate the two row renderers, that's
 * a separate refactor.
 */
export function TaskRow({
  task,
  placementCount,
  activePlacementCount,
  childCount,
  onClick,
}: TaskRowProps): React.ReactElement {
  const status = computeStatusLabel(task);
  const subtitle = computeSubtitle(task, childCount);
  const usage = computeUsageHint(placementCount, activePlacementCount);

  return (
    <button
      type="button"
      className={styles.row}
      onClick={() => onClick(task.id)}
      aria-label={`Open ${task.title || '(untitled task)'} details`}
    >
      <div className={styles.rowMain}>
        <TypeBadge type={typeLabel(task)} size="small" letterOnly />
        <div className={styles.rowText}>
          <span className={styles.rowTitle}>
            {task.title || '(untitled task)'}
          </span>
          {(subtitle || status || usage) && (
            <span className={styles.rowMeta}>
              {[subtitle, status, usage].filter(Boolean).join(' · ')}
            </span>
          )}
        </div>
      </div>
      <span className={styles.rowChevron} aria-hidden="true">›</span>
    </button>
  );
}

/** Map COMPOUND tasks to the user-facing "progress" or "composite"
 *  label so the badge colour matches the Tasks-tab filter chip the
 *  user used to find it. Other types pass through unchanged. */
function typeLabel(task: Task): string {
  if (task.type !== TaskType.COMPOUND) return task.type;
  return task.isOrdered === true ? 'progress' : 'composite';
}

function computeStatusLabel(task: Task): string {
  if (task.isCompleted) return 'Completed';
  if (task.type === TaskType.COUNTING) {
    const current = task.currentCount ?? 0;
    const max = task.maxCount ?? 0;
    if (current > 0 && max > 0) return `${current} / ${max}`;
  }
  return '';
}

function computeSubtitle(task: Task, childCount: number): string {
  if (task.type === TaskType.COUNTING) {
    // Reuse the canonical title generator so the subtitle matches what
    // the wizard / quick-add show on creation.
    if (task.action && task.unit && task.maxCount !== undefined) {
      return generateCounterTaskTitle(task.action, task.maxCount, task.unit);
    }
  }
  if (task.type === TaskType.COMPOUND) {
    if (childCount > 0) {
      return `${childCount} subtask${childCount === 1 ? '' : 's'}`;
    }
    return 'No subtasks yet';
  }
  if (task.type === TaskType.ACHIEVEMENT) {
    const trigger = task.achievementTrigger ?? 'greenlog';
    return trigger === 'bingo' ? 'On bingo' : 'On greenlog';
  }
  return '';
}

function computeUsageHint(total: number, active: number): string {
  if (total === 0) return 'Unused';
  if (active > 0) {
    return `On ${active} active board${active === 1 ? '' : 's'}`;
  }
  return `Placed on ${total} board${total === 1 ? '' : 's'}`;
}
