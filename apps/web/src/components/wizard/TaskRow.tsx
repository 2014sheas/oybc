import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import { RisoTypeBadge } from '../riso';
import styles from './BoardWizardTasksStep.module.css';

/**
 * TaskRow — shared task-row renderer, extracted from `BoardWizardTasksStep`
 * for the library sheet's task/leaf rows. (The Preview-deck `readOnly`
 * variant it once also served was retired with the deck in Board Sources
 * P4 — the 5b summary card renders its own rows.) Deliberately keeps
 * importing `BoardWizardTasksStep.module.css` — the class names are just
 * a CSS Modules scope, not tied to which `.tsx` file imports them.
 */

export interface TaskRowProps {
  task: Task;
  isSelected: boolean;
  onToggle?: () => void;
  /** Right-click handler — surfaces the same actions as a tap (toggle)
   *  plus center-task pinning when applicable. Mirrors iOS's
   *  `.contextMenu` long-press affordance. */
  onContextMenu?: (e: React.MouseEvent) => void;
  taskBoardCounts?: Record<string, number>;
  showCenterStar?: boolean;
  isCenter?: boolean;
  onCenterClick?: () => void;
}

export function renderTaskRow({
  task,
  isSelected,
  onToggle,
  onContextMenu,
  taskBoardCounts = {},
  showCenterStar = false,
  isCenter = false,
  onCenterClick,
}: TaskRowProps): React.ReactElement {
  const subtitle = buildTaskSubtitle(task);
  const boards = taskBoardCounts[task.id] ?? 0;
  const usageHint = boards === 0 ? 'unused' : `${boards} board${boards === 1 ? '' : 's'}`;
  return (
    <div className={isSelected ? styles.rowSelectedWrap : styles.rowWrap}>
      <button
        type="button"
        className={styles.row}
        onClick={onToggle}
        onContextMenu={onContextMenu}
        aria-pressed={isSelected}
      >
        <RisoTypeBadge type={task.type} />
        <div className={styles.rowCenter}>
          <span className={styles.rowTitle}>{task.title}</span>
          {subtitle && <span className={styles.rowSubtitle}>{subtitle}</span>}
        </div>
        <span className={styles.rowUsage}>{usageHint}</span>
      </button>
      {showCenterStar && (
        <button
          type="button"
          className={`${styles.centerRadio} ${isCenter ? styles.centerRadioOn : ''}`}
          onClick={onCenterClick}
          aria-label={isCenter ? 'Center task' : 'Mark as center task'}
          aria-pressed={isCenter}
          title={isCenter ? 'Center task' : 'Mark as center task'}
        >
          {isCenter ? '★' : '☆'}
        </button>
      )}
    </div>
  );
}

// ─── Subtitle helper (ported from compound wizard) ────────────────────────────

export function buildTaskSubtitle(task: Task): string {
  if (task.type === TaskType.COUNTING) {
    const { action, maxCount, unit } = task;
    if (!action || !unit || maxCount === undefined) return '';
    const derived = generateCounterTaskTitle(action, maxCount, unit);
    return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
  }
  // Compound-typed tasks never reach this helper — both call sites
  // (`visible.tasks` and expanded-leaf lists) filter TaskType.COMPOUND
  // out upstream; compound rows render their own subtitle via
  // `compositeLeafPreviews` instead.
  return '';
}
