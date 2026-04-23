import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  generateCounterTaskTitle,
  type Task,
  type CompositeNode,
  type CompositeTask,
} from '@oybc/shared';
import { db } from '../../db/database';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import { NewTaskSheet } from './NewTaskSheet';
import styles from './BoardWizardTasksStep.module.css';

const FILTER_TABS: { value: TasksFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

export type TasksFilter = 'all' | TaskType | 'composite';

export interface BoardWizardTasksStepProps {
  /** User's full task + composite library (from `useTaskLibrary`). */
  library: TaskLibrary;

  /** Currently-selected task ids — controlled by the wizard. */
  selectedTaskIds: Set<string>;
  /** Called when the user toggles a task's selection state. */
  onToggleSelection: (taskId: string) => void;

  /** Number of tasks the chosen board geometry requires. */
  tasksRequired: number;

  /** When true, every selected row shows a star radio for picking the
   *  center task. Driven by Step 1's center-type choice. */
  centerTaskMode: boolean;
  /** The currently-marked center task id, or `null` if none picked. */
  centerTaskId: string | null;
  /** Called when the user marks a different selected task as center. */
  onCenterTaskChange: (taskId: string | null) => void;

  /** Authenticated user id used by the inline new-task sheet. */
  userId: string;
  /** Fired after a non-composite task is created from the sheet — the
   *  wizard should auto-add the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /** Fired after a composite task is created from the sheet — the
   *  wizard should reload the library so the composite shows up. */
  onCompositeCreated: (ct: CompositeTask) => void;

  /** Navigates to the previous wizard step. */
  onBack: () => void;
  /** Navigates to the next wizard step. Disabled when validation fails. */
  onNext: () => void;
}

/**
 * BoardWizardTasksStep — Step 2 of the board-creation wizard.
 *
 * Renders the user's task library with multi-select, search, type
 * filter, and an inline "+ New task" sheet. Row layout matches the
 * composite wizard's Build step exactly: `[toggle] [BADGE letterOnly]
 * title + subtitle [usage hint]`, with a 3pt leading blue bar +
 * tinted background for the selected state. Hairline dividers between
 * rows — no per-row borders.
 *
 * Composites can't be added to a board directly (boards accept flat
 * tasks). The composite row uses a chevron instead of a checkbox and
 * expands inline to show its leaves; each leaf is rendered as a
 * normal task row, indented, so selection semantics are identical.
 * Replaces the earlier `CompositeDerivationPanel` + "+ Add to pool"
 * pattern which read as a different UI language.
 *
 * The component is controlled — `selectedTaskIds`, `centerTaskId`,
 * and navigation callbacks are owned by the wizard's state controller.
 * Internal state is UI-only (search query, active filter, expanded
 * composite, sheet open).
 */
export function BoardWizardTasksStep({
  library,
  selectedTaskIds,
  onToggleSelection,
  tasksRequired,
  centerTaskMode,
  centerTaskId,
  onCenterTaskChange,
  userId,
  onTaskCreated,
  onCompositeCreated,
  onBack,
  onNext,
}: BoardWizardTasksStepProps): React.ReactElement {
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilter, setActiveFilter] = useState<TasksFilter>('all');
  const [expandedCompositeId, setExpandedCompositeId] = useState<string | null>(null);
  const [isSheetOpen, setIsSheetOpen] = useState(false);

  // Usage-hint data — "N boards" / "unused" / "N steps" / "N subtasks".
  // Matches the composite wizard's library row hints so the two
  // surfaces agree at a glance. Board counts require a live query
  // since `useTaskLibrary` doesn't expose boardTasks.
  const allBoardTasks = useLiveQuery(() => db.boardTasks.toArray(), []) ?? [];

  const taskBoardCounts = useMemo(() => {
    const buckets = new Map<string, Set<string>>();
    for (const bt of allBoardTasks) {
      let set = buckets.get(bt.taskId);
      if (!set) {
        set = new Set<string>();
        buckets.set(bt.taskId, set);
      }
      set.add(bt.boardId);
    }
    const counts: Record<string, number> = {};
    for (const [taskId, set] of buckets) counts[taskId] = set.size;
    return counts;
  }, [allBoardTasks]);

  const taskStepCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const s of library.allTaskSteps) {
      counts[s.taskId] = (counts[s.taskId] ?? 0) + 1;
    }
    return counts;
  }, [library.allTaskSteps]);

  const compositeSubtaskCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const n of library.allCompositeNodes) {
      if (n.nodeType !== 'leaf') continue;
      counts[n.compositeTaskId] = (counts[n.compositeTaskId] ?? 0) + 1;
    }
    return counts;
  }, [library.allCompositeNodes]);

  const compositeLeafPreviews = useMemo(() => {
    const previews: Record<string, { titles: string[]; totalLeaves: number }> = {};
    const leavesByComposite = new Map<string, CompositeNode[]>();
    for (const n of library.allCompositeNodes) {
      if (n.nodeType !== 'leaf') continue;
      const arr = leavesByComposite.get(n.compositeTaskId) ?? [];
      arr.push(n);
      leavesByComposite.set(n.compositeTaskId, arr);
    }
    for (const [cid, leaves] of leavesByComposite) {
      leaves.sort((a, b) => a.nodeIndex - b.nodeIndex);
      const titles: string[] = [];
      for (const leaf of leaves.slice(0, 3)) {
        if (leaf.taskId) {
          const t = library.taskMap[leaf.taskId];
          if (t) titles.push(t.title);
        } else if (leaf.childCompositeTaskId) {
          const cc = library.compositeTaskMap[leaf.childCompositeTaskId];
          if (cc) titles.push(cc.title);
        }
      }
      previews[cid] = { titles, totalLeaves: leaves.length };
    }
    return previews;
  }, [library.allCompositeNodes, library.taskMap, library.compositeTaskMap]);

  // Resolve a composite's leaf tasks (flat, normal tasks only — nested
  // composites aren't boardable). Used when rendering the expanded leaf
  // list. Keyed by composite id for memoisation.
  const compositeLeafTasks = useMemo(() => {
    const byComposite: Record<string, Task[]> = {};
    const leavesByComposite = new Map<string, CompositeNode[]>();
    for (const n of library.allCompositeNodes) {
      if (n.nodeType !== 'leaf') continue;
      const arr = leavesByComposite.get(n.compositeTaskId) ?? [];
      arr.push(n);
      leavesByComposite.set(n.compositeTaskId, arr);
    }
    for (const [cid, leaves] of leavesByComposite) {
      leaves.sort((a, b) => a.nodeIndex - b.nodeIndex);
      const tasks: Task[] = [];
      for (const leaf of leaves) {
        if (leaf.taskId) {
          const t = library.taskMap[leaf.taskId];
          if (t) tasks.push(t);
        }
      }
      byComposite[cid] = tasks;
    }
    return byComposite;
  }, [library.allCompositeNodes, library.taskMap]);

  const visible = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    const matches = (title: string): boolean =>
      q.length === 0 || title.toLowerCase().includes(q);

    const tasks =
      activeFilter === 'all'
        ? library.allTasks.filter((t) => matches(t.title))
        : activeFilter === 'composite'
          ? []
          : library.allTasks.filter((t) => t.type === activeFilter && matches(t.title));

    const composites =
      activeFilter === 'all' || activeFilter === 'composite'
        ? library.allCompositeTasks.filter((ct) => matches(ct.title))
        : [];

    return { tasks, composites };
  }, [library, activeFilter, searchQuery]);

  const selectedCount = selectedTaskIds.size;
  const isCountSatisfied = selectedCount >= tasksRequired;
  const isCenterSatisfied =
    !centerTaskMode || (centerTaskId !== null && selectedTaskIds.has(centerTaskId));
  const canAdvance = isCountSatisfied && isCenterSatisfied;

  function handleToggle(taskId: string): void {
    const wasSelected = selectedTaskIds.has(taskId);
    onToggleSelection(taskId);
    if (wasSelected && centerTaskId === taskId) {
      onCenterTaskChange(null);
    }
  }

  function handleCenterRadio(taskId: string): void {
    onCenterTaskChange(centerTaskId === taskId ? null : taskId);
  }

  return (
    <div className={styles.container}>
      {/* Header — selection count, search, filter */}
      <div className={styles.header}>
        <div className={styles.countRow}>
          <div className={styles.countGroup}>
            <span className={styles.countLabel}>
              Selected:{' '}
              <span className={isCountSatisfied ? styles.countOk : styles.countShort}>
                {selectedCount} / {tasksRequired}
              </span>
            </span>
            {centerTaskMode && (
              <span
                className={
                  centerTaskId !== null && selectedTaskIds.has(centerTaskId)
                    ? styles.centerBadgeOk
                    : styles.centerBadgeWarn
                }
              >
                {centerTaskId !== null && selectedTaskIds.has(centerTaskId)
                  ? '★ Center picked'
                  : '★ Center required'}
              </span>
            )}
          </div>
          <button
            type="button"
            className={styles.newTaskButton}
            onClick={() => setIsSheetOpen(true)}
          >
            + New task
          </button>
        </div>

        <input
          type="search"
          className={styles.search}
          placeholder="Search your tasks…"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />

        <FilterTabs
          tabs={FILTER_TABS}
          activeTab={activeFilter}
          onTabChange={(value) => {
            setActiveFilter(value as TasksFilter);
            setExpandedCompositeId(null);
          }}
        />
      </div>

      {/* List */}
      {visible.tasks.length === 0 && visible.composites.length === 0 ? (
        <div className={styles.emptyState}>
          {searchQuery.trim().length > 0
            ? `No tasks match "${searchQuery}".`
            : 'Your task library is empty. Tap "New task" above to create your first one.'}
        </div>
      ) : (
        <ul className={styles.list}>
          {visible.tasks.map((task) => {
            const isSelected = selectedTaskIds.has(task.id);
            const isCenter = centerTaskId === task.id;
            return (
              <li key={task.id}>
                {renderTaskRow({
                  task,
                  isSelected,
                  onToggle: () => handleToggle(task.id),
                  taskBoardCounts,
                  taskStepCounts,
                  showCenterStar: centerTaskMode && isSelected,
                  isCenter,
                  onCenterClick: () => handleCenterRadio(task.id),
                })}
              </li>
            );
          })}

          {visible.composites.map((ct) => {
            const isExpanded = expandedCompositeId === ct.id;
            const leafCount = compositeSubtaskCounts[ct.id] ?? 0;
            const preview = compositeLeafPreviews[ct.id];
            const previewSubtitle = preview && preview.titles.length > 0
              ? (preview.totalLeaves > preview.titles.length
                  ? `${preview.titles.join(', ')}, +${preview.totalLeaves - preview.titles.length} more`
                  : preview.titles.join(', '))
              : '';
            const leaves = compositeLeafTasks[ct.id] ?? [];
            return (
              <li key={ct.id}>
                <button
                  type="button"
                  className={styles.row}
                  onClick={() =>
                    setExpandedCompositeId((prev) => (prev === ct.id ? null : ct.id))
                  }
                  aria-expanded={isExpanded}
                >
                  <span className={styles.leadingBar} aria-hidden="true" />
                  <span
                    className={`${styles.chevron} ${isExpanded ? styles.chevronOpen : ''}`}
                    aria-hidden="true"
                  >
                    ▶
                  </span>
                  <TypeBadge type="composite" size="small" letterOnly />
                  <div className={styles.rowCenter}>
                    <span className={styles.rowTitle}>{ct.title}</span>
                    {previewSubtitle && (
                      <span className={styles.rowSubtitle}>{previewSubtitle}</span>
                    )}
                  </div>
                  <span className={styles.rowUsage}>
                    {leafCount} subtask{leafCount === 1 ? '' : 's'}
                  </span>
                </button>

                {isExpanded && (
                  <ul className={styles.leafList}>
                    {leaves.length === 0 && (
                      <li className={styles.leafEmpty}>
                        This composite has no task leaves — nothing boardable here.
                      </li>
                    )}
                    {leaves.map((leafTask) => {
                      const isSelected = selectedTaskIds.has(leafTask.id);
                      const isCenter = centerTaskId === leafTask.id;
                      return (
                        <li key={leafTask.id} className={styles.leafItem}>
                          {renderTaskRow({
                            task: leafTask,
                            isSelected,
                            onToggle: () => handleToggle(leafTask.id),
                            taskBoardCounts,
                            taskStepCounts,
                            showCenterStar: centerTaskMode && isSelected,
                            isCenter,
                            onCenterClick: () => handleCenterRadio(leafTask.id),
                          })}
                        </li>
                      );
                    })}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {/* Footer — actions */}
      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack}>
          ‹ Back
        </button>
        <button
          type="button"
          className={styles.nextButton}
          onClick={onNext}
          disabled={!canAdvance}
          title={
            !isCountSatisfied
              ? (() => {
                  const n = tasksRequired - selectedCount;
                  return `Pick ${n} more task${n === 1 ? '' : 's'}`;
                })()
              : !isCenterSatisfied
                ? 'Mark one selected task as the center'
                : undefined
          }
        >
          Next ›
        </button>
      </div>

      <NewTaskSheet
        isOpen={isSheetOpen}
        onClose={() => setIsSheetOpen(false)}
        userId={userId}
        onTaskCreated={(task) => {
          onTaskCreated(task);
        }}
        onCompositeCreated={(ct) => {
          onCompositeCreated(ct);
        }}
      />
    </div>
  );
}

// ─── Row renderer (shared between top-level tasks and expanded leaves) ────────

interface TaskRowProps {
  task: Task;
  isSelected: boolean;
  onToggle: () => void;
  taskBoardCounts: Record<string, number>;
  taskStepCounts: Record<string, number>;
  showCenterStar: boolean;
  isCenter: boolean;
  onCenterClick: () => void;
}

function renderTaskRow({
  task,
  isSelected,
  onToggle,
  taskBoardCounts,
  taskStepCounts,
  showCenterStar,
  isCenter,
  onCenterClick,
}: TaskRowProps): React.ReactElement {
  const subtitle = buildTaskSubtitle(task, taskStepCounts);
  const boards = taskBoardCounts[task.id] ?? 0;
  const usageHint = boards === 0 ? 'unused' : `${boards} board${boards === 1 ? '' : 's'}`;
  return (
    <div className={isSelected ? styles.rowSelectedWrap : styles.rowWrap}>
      <button
        type="button"
        className={styles.row}
        onClick={onToggle}
        aria-pressed={isSelected}
      >
        <span className={styles.leadingBar} aria-hidden="true" />
        <span
          className={isSelected ? styles.checkboxOn : styles.checkbox}
          aria-hidden="true"
        >
          {isSelected ? '✓' : ''}
        </span>
        <TypeBadge type={task.type} size="small" letterOnly />
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

// ─── Subtitle helper (ported from composite wizard) ──────────────────────────

function buildTaskSubtitle(
  task: Task,
  taskStepCounts: Record<string, number>,
): string {
  if (task.type === TaskType.COUNTING) {
    const { action, maxCount, unit } = task;
    if (!action || !unit || maxCount === undefined) return '';
    const derived = generateCounterTaskTitle(action, maxCount, unit);
    return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
  }
  if (task.type === TaskType.PROGRESS) {
    const n = taskStepCounts[task.id] ?? 0;
    if (n === 0) return '';
    return `${n} step${n === 1 ? '' : 's'}`;
  }
  return '';
}
