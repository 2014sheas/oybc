import { formatCounterName, generateCounterTaskTitle, TaskType, type Task } from '@oybc/shared';
import { RisoTypeBadge } from '../../components/riso';
import { computeStatusLabel } from './taskCountDisplay';
import { formatRelativeTime } from '../../utils/relativeTime';
import styles from './TaskRow.module.css';

export interface TaskRowProps {
  task: Task;
  /** Pre-computed count of non-deleted `BoardTask` placements. */
  placementCount: number;
  /** Pre-computed count of placements on ACTIVE boards specifically.
   *  Drives the "On N active boards" hint. */
  activePlacementCount: number;
  /** False while the placement join is unresolved — the usage line is
   *  omitted rather than claiming "Unused" (late-mutation audit). */
  usageCountsLoaded?: boolean;
  /** Pre-computed count of compound children (for compound-type tasks).
   *  Skipped for any other type. */
  childCount: number;
  onClick: (taskId: string) => void;
  /** Quick-action: open the edit sheet for this task without
   *  navigating to the detail page. Omit to hide the ✎ button. */
  onEdit?: (taskId: string) => void;
  /** Quick-action: open the delete confirm dialog for this task without
   *  navigating to the detail page. Omit to hide the ✕ button. */
  onDelete?: (taskId: string) => void;
  /** Issue #73 — when set, render a leading disclosure chevron (used for a
   *  top-level compound that has children to nest). */
  isExpandable?: boolean;
  /** Whether this expandable row is currently open. */
  isExpanded?: boolean;
  /** Fired when the disclosure chevron is tapped. */
  onToggleExpand?: (taskId: string) => void;
  /** Owner ruling 2026-09-22 — this task HEADS a shared-counter family
   *  (`sharedCounterRootIds`). The library shows one GENERIC row per family:
   *  the pair-derived `formatCounterName` label ("Read pages") in place of the
   *  stored title, NO count anywhere on the row (title, subtitle and status
   *  alike), and a tap that opens the Counters hub rather than Task detail
   *  (the caller routes; this flag only changes the copy and the a11y wording
   *  so the two agree).
   *
   *  This row and iOS `RisoTaskRowView` are twins — the generic label, the
   *  count-free treatment and the "Counter" subtitle must stay identical on
   *  both. Change one, change the other in the same commit. */
  isFamilyRoot?: boolean;
}

/**
 * TaskRow — single list row on the Tasks tab.
 *
 * Three side-by-side surfaces inside one outer `<div>`:
 *   1. The main button: title + type badge + one-line status/usage
 *      hint + trailing chevron. Tapping it navigates to the detail page.
 *   2. Trailing ✎ button (optional): quick-action edit, opens the
 *      `TaskEditSheet` over the list without navigating.
 *   3. Trailing ✕ button (optional): quick-action delete, opens the
 *      `TaskConfirmDeleteDialog` over the list.
 *
 * Mirrors the `BoardListItem` pattern from PR #58: nested `<button>`s
 * are invalid HTML, so the row is an outer `<div>` and each button is
 * a sibling. The web doesn't have iOS-style swipe gestures, so persistent
 * trailing icons are the affordance.
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
  usageCountsLoaded = true,
  childCount,
  onClick,
  onEdit,
  onDelete,
  isExpandable = false,
  isExpanded = false,
  onToggleExpand,
  isFamilyRoot = false,
}: TaskRowProps): React.ReactElement {
  // A family root carries NO count anywhere on the row — not in the title, not
  // in the subtitle, and not in the status slot, whose counting branch is
  // `{current} / {max}`. iOS's twin row has no count column at all, so leaving
  // this in would also be a fresh parity gap.
  const status = isFamilyRoot ? '' : computeStatusLabel(task);
  const subtitle = computeSubtitle(task, childCount, isFamilyRoot);
  // Unknown ≠ unused: render nothing until the placement join resolves
  // (late-mutation audit, shape B) — "Unused" flipping to "On 3 active
  // boards" is a false claim corrected in front of the user.
  const usage = usageCountsLoaded
    ? computeUsageHint(placementCount, activePlacementCount)
    : null;
  const lastCompleted = task.completedAt ? formatRelativeTime(task.completedAt) : null;
  // A family root reads as the counter itself ("Read pages"), never as one
  // window's target ("Read 5 pages"). `formatCounterName` returns '' when the
  // (action, unit) pair can't produce a name — the same stored-title fallback
  // `sharedCounterGroups.ts` uses.
  const displayTitle = isFamilyRoot
    ? formatCounterName(task.action, task.unit) || task.title
    : task.title;
  const titleForA11y = displayTitle || '(untitled task)';

  return (
    <div className={styles.row}>
      {isExpandable && (
        <button
          type="button"
          className={styles.disclosureButton}
          onClick={() => onToggleExpand?.(task.id)}
          aria-label={isExpanded ? `Collapse ${titleForA11y}` : `Expand ${titleForA11y}`}
          aria-expanded={isExpanded}
          title={isExpanded ? 'Collapse subtasks' : 'Expand subtasks'}
        >
          <span aria-hidden="true">{isExpanded ? '▾' : '▸'}</span>
        </button>
      )}
      <button
        type="button"
        className={styles.mainButton}
        onClick={() => onClick(task.id)}
        aria-label={
          isFamilyRoot ? `Open the ${titleForA11y} counter` : `Open ${titleForA11y} details`
        }
      >
        <div className={styles.rowMain}>
          <RisoTypeBadge type={task.type} />
          <div className={styles.rowText}>
            <span className={styles.rowTitle}>{titleForA11y}</span>
            {(subtitle || status || lastCompleted || usage) && (
              <span className={styles.rowMeta}>
                {[subtitle, status, lastCompleted ? `Last completed ${lastCompleted}` : '', usage ?? '']
                  .filter(Boolean)
                  .join(' · ')}
              </span>
            )}
          </div>
        </div>
        <span className={styles.rowChevron} aria-hidden="true">›</span>
      </button>

      {onEdit && (
        <button
          type="button"
          className={styles.editButton}
          onClick={() => onEdit(task.id)}
          aria-label={`Edit ${titleForA11y}`}
          title="Edit task"
        >
          ✎
        </button>
      )}

      {onDelete && (
        <button
          type="button"
          className={styles.deleteButton}
          onClick={() => onDelete(task.id)}
          aria-label={`Delete ${titleForA11y}`}
          title="Delete task"
        >
          ✕
        </button>
      )}
    </div>
  );
}

function computeSubtitle(task: Task, childCount: number, isFamilyRoot: boolean): string {
  if (task.type === TaskType.COUNTING) {
    // A family root must not restate a goal anywhere on the row — the whole
    // point of the generic row is that the family's targets live in the hub,
    // one per window. Keep the word in lockstep with the iOS twin
    // (`RisoTaskRowView.subtitle`).
    if (isFamilyRoot) return 'Counter';
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
