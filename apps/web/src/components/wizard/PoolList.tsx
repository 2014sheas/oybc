import { useState } from 'react';
import { AchievementTrigger, OperatorType, TaskType, type CompoundChild, type Task } from '@oybc/shared';
import { TypeBadge } from '../TypeBadge';
import styles from './PoolList.module.css';

export interface PoolListProps {
  /** Insertion order (`useBoardWizard.poolOrder`) — renders in THIS order,
   *  never re-sorted, so a later inline rename (PR-2) can't reshuffle the
   *  list. Ids without a resolvable task (mid-hydration race) are skipped. */
  poolOrder: string[];
  effectiveTaskMap: Record<string, Task>;
  effectiveChildrenByCompound: Record<string, CompoundChild[]>;
  taskBoardCounts: Record<string, number>;

  centerTaskMode: boolean;
  centerTaskId: string | null;
  onCenterClick: (taskId: string) => void;

  /** Removes the row. Routes through the wizard's `onToggleSelection` so
   *  the Bug #85 `pendingTasks` purge still fires on a pending task. */
  onRemove: (taskId: string) => void;
  onContextMenu: (taskId: string, x: number, y: number) => void;

  /**
   * Web inline-editing port PR-2 — the currently-open editor row (at most
   * one at a time), or `null` when no row is being edited. Mirrors iOS
   * `RisoPoolListView.editingTaskId`.
   */
  editingTaskId?: string | null;
  /** Opens the inline editor for a row (the ✎ pencil). Ignored for
   *  Achievement rows (read-only in the pool). */
  onEdit?: (taskId: string) => void;
  /**
   * Render-prop for the open row's editor body — owned by the container
   * (`BoardWizardTasksStep`) so this component stays a pure list renderer
   * and doesn't need its own draft state. Mirrors iOS `RisoPoolListView`'s
   * `editor` closure parameter.
   */
  editor?: (task: Task) => React.ReactNode;

  /**
   * Board Sources P4 — when set, the header count pill shows THIS value
   * (the sources capacity) instead of the hand-added row count. Mirrors
   * iOS `RisoPoolListView.countOverride`.
   */
  countOverride?: number;
  /**
   * Board Sources P4 — source rows rendered at the TOP of the list,
   * before the hand-added task rows. Mirrors iOS `leadingRows`.
   */
  leadingRows?: React.ReactNode;
  /**
   * Counter-family exclusivity — task id → the OTHER family member's
   * title, for tasks whose shared-counter family has ≥2 members in the
   * pool. Renders the "shares a counter with 'X' · one per board" hint.
   */
  counterClashByTaskId?: Map<string, string>;
}

/**
 * PoolList — "ON YOUR BOARD" section of the wizard Tasks step (Web
 * inline-editing port PR-1, porting iOS `RisoPoolListView`'s resting-row
 * layout only — the inline editor is PR-2).
 *
 * Every row here is on the board, so every row is blue-tinted with a 4px
 * leading bar. Row body: 4-letter `TypeBadge` (letterOnly) + title +
 * subtitle + trailing usage hint; compound rows expand a read-only
 * sub-task preview on body click. Trailing gutter is exactly three 46px
 * slots with hairline dividers — ☆/★ center radio (only rendered at all
 * when `centerTaskMode` is on, so the gutter is consistently 2 or 3 slots
 * across the whole list, never per-row) · ✎ edit (opens the inline editor
 * in place, PR-2; achievement rows get an empty placeholder instead, since
 * achievements are never inline-editable) · ✕ remove.
 */
export function PoolList({
  poolOrder,
  effectiveTaskMap,
  effectiveChildrenByCompound,
  taskBoardCounts,
  centerTaskMode,
  centerTaskId,
  onCenterClick,
  onRemove,
  onContextMenu,
  editingTaskId = null,
  onEdit,
  editor,
  countOverride,
  leadingRows,
  counterClashByTaskId,
}: PoolListProps): React.ReactElement {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const poolTasks = poolOrder
    .map((id) => effectiveTaskMap[id])
    .filter((t): t is Task => t !== undefined);

  return (
    <div className={styles.section}>
      <div className={styles.sectionHeader}>
        <span className={styles.sectionLabel}>On your board</span>
        <span className={styles.countPill}>{countOverride ?? poolTasks.length}</span>
      </div>

      {poolTasks.length === 0 && !leadingRows ? (
        <p className={styles.emptyNote}>
          Nothing in your pool yet — reuse a task, type your own, or add a special type.
        </p>
      ) : (
        <ul className={styles.list}>
          {leadingRows}
          {poolTasks.map((task) => {
            const isCompound = task.type === TaskType.COMPOUND;
            const isCenter = centerTaskMode && centerTaskId === task.id;
            const isExpanded = expandedId === task.id;
            const clashTitle = counterClashByTaskId?.get(task.id);
            const subtitle = buildPoolRowSubtitle(
              task,
              effectiveChildrenByCompound[task.id] ?? [],
              clashTitle,
            );
            const boardCount = taskBoardCounts[task.id] ?? 0;
            const usageHint = isCompound
              ? `${effectiveChildrenByCompound[task.id]?.length ?? 0} subtask${
                  (effectiveChildrenByCompound[task.id]?.length ?? 0) === 1 ? '' : 's'
                }`
              : boardCount === 0
                ? 'unused'
                : `${boardCount} board${boardCount === 1 ? '' : 's'}`;

            if (editingTaskId === task.id && editor) {
              return (
                <li key={task.id} className={styles.row}>
                  {editor(task)}
                </li>
              );
            }

            return (
              <li key={task.id} className={styles.row}>
                <div
                  className={styles.rowBody}
                  role={isCompound ? 'button' : undefined}
                  tabIndex={isCompound ? 0 : undefined}
                  onClick={isCompound ? () => setExpandedId((p) => (p === task.id ? null : task.id)) : undefined}
                  onKeyDown={
                    isCompound
                      ? (e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            setExpandedId((p) => (p === task.id ? null : task.id));
                          }
                        }
                      : undefined
                  }
                  onContextMenu={(e) => {
                    e.preventDefault();
                    onContextMenu(task.id, e.clientX, e.clientY);
                  }}
                >
                  <TypeBadge type={task.type} letterOnly />
                  <div className={styles.rowText}>
                    <span className={styles.rowTitle}>{task.title || '(untitled task)'}</span>
                    {subtitle && <span className={styles.rowSubtitle}>{subtitle}</span>}
                  </div>
                  <span className={styles.rowUsage}>{usageHint}</span>
                  {isCompound && (
                    <span className={`${styles.chevron} ${isExpanded ? styles.chevronOpen : ''}`} aria-hidden="true">
                      ▶
                    </span>
                  )}
                </div>

                <div className={styles.gutter}>
                  {centerTaskMode && (
                    <button
                      type="button"
                      className={styles.gutterSlot}
                      onClick={() => onCenterClick(task.id)}
                      aria-label={isCenter ? 'Center task' : 'Mark as center task'}
                      aria-pressed={isCenter}
                      title={isCenter ? 'Center task' : 'Mark as center task'}
                    >
                      <span className={isCenter ? styles.starOn : styles.starOff}>{isCenter ? '★' : '☆'}</span>
                    </button>
                  )}
                  {task.type === TaskType.ACHIEVEMENT ? (
                    <div className={styles.gutterSlot} aria-hidden="true" />
                  ) : (
                    <button
                      type="button"
                      className={styles.gutterSlot}
                      onClick={() => onEdit?.(task.id)}
                      aria-label={`Edit ${task.title || 'task'}`}
                      title="Edit task"
                    >
                      <span className={styles.pencilGlyph}>✎</span>
                    </button>
                  )}
                  <button
                    type="button"
                    className={styles.gutterSlot}
                    onClick={() => onRemove(task.id)}
                    aria-label={`Remove ${task.title || 'task'} from board`}
                    title="Remove from board"
                  >
                    <span className={styles.removeGlyph}>✕</span>
                  </button>
                </div>

                {isCompound && isExpanded && (
                  <div className={styles.childrenPreview}>
                    {(effectiveChildrenByCompound[task.id] ?? []).length === 0 ? (
                      <span className={styles.childrenEmpty}>No sub-tasks yet.</span>
                    ) : (
                      (effectiveChildrenByCompound[task.id] ?? []).map((child) => {
                        const childTask = effectiveTaskMap[child.childTaskId];
                        if (!childTask) return null;
                        return (
                          <span key={child.id} className={styles.childPill}>
                            <TypeBadge type={childTask.type} letterOnly size="small" />
                            {childTask.title || '(untitled task)'}
                          </span>
                        );
                      })
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

/** Type-specific detail line — mirrors iOS
 *  `RisoPoolListView.typeDetailSubtitle`. (Board Sources P4 dropped the
 *  provenance suffix — the design's copy rule bans provenance subtitles.
 *  `clashTitle` appends the counter-family "one per board" hint.) */
function buildPoolRowSubtitle(
  task: Task,
  children: CompoundChild[],
  clashTitle?: string,
): string | undefined {
  let base: string | undefined;
  switch (task.type) {
    case TaskType.COUNTING: {
      const { action, unit, maxCount } = task;
      if (action && unit && maxCount !== undefined) {
        base = `${action} · goal ${maxCount} ${unit}`;
      }
      break;
    }
    case TaskType.COMPOUND: {
      const n = children.length;
      if (n > 0) {
        const op = task.operator;
        const ruleLabel =
          op === OperatorType.OR
            ? `any of ${n}`
            : op === OperatorType.M_OF_N
              ? `at least ${task.threshold ?? n} of ${n}`
              : `all of ${n}`;
        base = `${n} sub-task${n === 1 ? '' : 's'} · ${ruleLabel}`;
      }
      break;
    }
    case TaskType.ACHIEVEMENT: {
      const trigger = task.achievementTrigger === AchievementTrigger.BINGO ? 'First Bingo' : 'GREENLOG';
      const target = task.referencedBoardId ? 'a board' : 'a repeating board';
      base = `Watch ${target} · ${trigger}`;
      break;
    }
    default:
      base = undefined;
  }
  if (clashTitle !== undefined) {
    const hint = `shares a counter with “${clashTitle}” · one per board`;
    return base !== undefined ? `${base} · ${hint}` : hint;
  }
  return base;
}
