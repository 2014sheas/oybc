import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import { RisoTypeBadge } from '../riso';
import styles from './BoardWizardTasksStep.module.css';

/**
 * TaskRow — shared task-row renderer, extracted from `BoardWizardTasksStep`
 * (P4, Task Pools + Recurring Boards Rework) so the Preview step's
 * repeating-board deck list (docs/POOLS_RECURRING.md §Surfaces item 5's
 * list-with-provenance UI) reuses the EXACT same row instead of a second
 * copy (CLAUDE.md "reuse before creating"). Deliberately keeps importing
 * `BoardWizardTasksStep.module.css` — the class names are just a CSS
 * Modules scope, not tied to which `.tsx` file imports them, so both
 * call sites render pixel-identical rows without duplicating CSS.
 */

export interface TaskRowProps {
  task: Task;
  isSelected: boolean;
  onToggle?: () => void;
  /** Right-click handler — surfaces the same actions as a tap (toggle)
   *  plus center-task pinning when applicable. Mirrors iOS's
   *  `.contextMenu` long-press affordance. Ignored when `readOnly`. */
  onContextMenu?: (e: React.MouseEvent) => void;
  taskBoardCounts?: Record<string, number>;
  showCenterStar?: boolean;
  isCenter?: boolean;
  onCenterClick?: () => void;
  /** P3 — provenance label ("from X" / "added by hand"), rendered only
   *  when the row is selected. `undefined` renders nothing (unselected
   *  rows never pass this). */
  provenance?: string;
  /**
   * P4 — when true, renders a non-interactive row (a `div`, not a
   * `button`; no usage-hint column, no center star) for read-only
   * contexts like the Preview step's repeating-board deck list, which
   * shows the resolved selection but isn't a place to toggle it (that
   * happens back on the Tasks step).
   */
  readOnly?: boolean;
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
  provenance,
  readOnly = false,
}: TaskRowProps): React.ReactElement {
  const subtitle = buildTaskSubtitle(task);

  if (readOnly) {
    return (
      <div className={styles.rowWrap}>
        <div className={styles.row}>
          <RisoTypeBadge type={task.type} />
          <div className={styles.rowCenter}>
            <span className={styles.rowTitle}>{task.title}</span>
            {subtitle && <span className={styles.rowSubtitle}>{subtitle}</span>}
            {provenance && <span className={styles.rowProvenance}>{provenance}</span>}
          </div>
        </div>
      </div>
    );
  }

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
          {isSelected && provenance && <span className={styles.rowProvenance}>{provenance}</span>}
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
