import { useEffect, useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  PARENT_TIMEFRAMES,
  TaskType,
  Timeframe,
  generateCounterTaskTitle,
  isTaskExpired,
  type Task,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { useParentBoardTasks } from '../../hooks';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import { CopyTaskModal } from './CopyTaskModal';
import { DeriveCounterModal } from './DeriveCounterModal';
import { FromBoardGrid } from './FromBoardGrid';
import { FromBoardPicker } from './FromBoardPicker';
import { NewTaskSheet } from './NewTaskSheet';
import { RowContextMenu } from './RowContextMenu';
import { TaskDetailSheet } from '../TaskDetailSheet';
import styles from './BoardWizardTasksStep.module.css';

const BASE_FILTER_TABS: { value: TasksFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  // 'progress' is a local string sentinel (NOT TaskType.PROGRESS, which is
  // a deprecated alias being removed in Phase 8). The filter logic below
  // maps it to compound+isOrdered=true. Same pattern as 'composite' for
  // compound+isOrdered=false.
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

const FROM_PARENTS_TAB: { value: TasksFilter; label: string } = {
  value: 'from-parents',
  label: 'From parent boards',
};

const FROM_BOARD_TAB: { value: TasksFilter; label: string } = {
  value: 'from-board',
  label: 'From a board…',
};

export type TasksFilter =
  | 'all'
  | TaskType
  | 'progress'
  | 'composite'
  | 'from-parents'
  | 'from-board';

export interface BoardWizardTasksStepProps {
  /** User's full task + composite library (from `useTaskLibrary`). */
  library: TaskLibrary;

  /** Currently-selected task ids — controlled by the wizard. */
  selectedTaskIds: Set<string>;
  /** Called when the user toggles a task's selection state. */
  onToggleSelection: (taskId: string) => void;

  /** Number of tasks the chosen board geometry requires. */
  tasksRequired: number;

  /** True when the wizard is in recurring-template mode. Drives the
   *  count-line "min" suffix wording. The pool is always loose-fit;
   *  the spawn shuffles + slices, so any extras become the random
   *  subset. */
  isRecurring: boolean;

  /** When true, every selected row shows a star radio for picking the
   *  center task. Driven by Step 1's center-type choice. */
  centerTaskMode: boolean;
  /** The currently-marked center task id, or `null` if none picked. */
  centerTaskId: string | null;
  /** Called when the user marks a different selected task as center. */
  onCenterTaskChange: (taskId: string | null) => void;

  /** Authenticated user id used by the inline new-task sheet. */
  userId: string;
  /** Current wizard timeframe. Drives whether the "From parent boards"
   *  filter chip is shown (only for child timeframes — daily, weekly,
   *  monthly) and what timeframe to feed `useParentBoardTasks`. */
  currentTimeframe: Timeframe;
  /** Phase 6.Y — Timeboxed Tasks. The resolved start/end dates the
   *  wizard will write on the board. Threaded into NewTaskSheet so
   *  any new task created from inside the wizard inherits the same
   *  timeboxed window as its parent board. */
  currentStartDate?: string;
  currentEndDate?: string;
  /** Fired after a non-composite task is created from the sheet — the
   *  wizard should auto-add the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /** Fired after a compound (formerly composite) task is created from the
   *  sheet — the wizard should reload the library so the compound shows up.
   *  Under the unified model composites are Tasks, so the callback uses Task. */
  onCompositeCreated: (task: Task) => void;

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
  isRecurring,
  centerTaskMode,
  centerTaskId,
  onCenterTaskChange,
  userId,
  currentTimeframe,
  currentStartDate,
  currentEndDate,
  onTaskCreated,
  onCompositeCreated,
  onBack,
  onNext,
}: BoardWizardTasksStepProps): React.ReactElement {
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilter, setActiveFilter] = useState<TasksFilter>('all');

  // "From parent boards" filter chip is only meaningful when the current
  // timeframe HAS parents — yearly has none; custom is excluded from
  // recurrence. Hide the chip otherwise to avoid an always-empty filter.
  const hasParentTimeframes = PARENT_TIMEFRAMES[currentTimeframe].length > 0;

  // `From a board…` is unconditionally available (no timeframe gating)
  // since any wizard timeframe is a valid context for browsing another
  // board. Sits AFTER `From parent boards` so the parent-tasks chip
  // stays in its established position.
  const filterTabs = useMemo(
    () =>
      hasParentTimeframes
        ? [...BASE_FILTER_TABS, FROM_PARENTS_TAB, FROM_BOARD_TAB]
        : [...BASE_FILTER_TABS, FROM_BOARD_TAB],
    [hasParentTimeframes]
  );

  // Coerce the active filter back to 'all' if the user picked
  // 'from-parents' on a timeframe with parents (e.g., daily) and then
  // backed out to Step 1 and switched to a parentless timeframe (yearly /
  // custom). Without this, the chip disappears from the tab row but
  // `activeFilter` remains 'from-parents' — leaving no tab visually
  // selected and showing the "No parent boards" empty state instead of
  // the user's library.
  useEffect(() => {
    if (!hasParentTimeframes && activeFilter === 'from-parents') {
      setActiveFilter('all');
    }
  }, [hasParentTimeframes, activeFilter]);

  // Reactive list of unique tasks placed on currently-active parent boards.
  // Always called (hooks rule) but returns [] when timeframe has no parents,
  // so it's effectively a no-op for yearly/custom.
  const parentBoardTasks = useParentBoardTasks(userId, currentTimeframe);
  const [expandedCompositeId, setExpandedCompositeId] = useState<string | null>(null);
  const [isSheetOpen, setIsSheetOpen] = useState(false);
  /** Right-click context menu state. Null when no menu is open. Stores
   *  the target task's id + cursor position; actions are derived at render
   *  time from the task's type (compound vs primitive). Mirrors the iOS
   *  `.contextMenu` long-press affordance on `BoardWizardTasksStepView`. */
  const [rowContextMenu, setRowContextMenu] = useState<
    { taskId: string; x: number; y: number } | null
  >(null);
  /** Source counting task + draft new maxCount for the "derive smaller
   *  version" quick action. Null when the deriver modal is closed. */
  const [derivingFromTask, setDerivingFromTask] = useState<Task | null>(null);
  const [deriveMaxCountInput, setDeriveMaxCountInput] = useState('');
  const [deriveError, setDeriveError] = useState<string | null>(null);
  /** `From a board…` filter state. `null` = picker mode (no source
   *  chosen yet); set = grid mode for that board. Selection itself
   *  lives in `selectedTaskIds` (wizard-owned), so swapping sources
   *  doesn't lose what the user has already linked. */
  const [pickedSourceBoardId, setPickedSourceBoardId] = useState<string | null>(null);
  /** Task ids copied via the From-a-board grid's `⎘ Add a copy…`
   *  this session. Used to render the amber-tint indicator on source
   *  squares whose original we've already copied. Cleared on remount
   *  (session-scoped). */
  const [copiedTaskIds, setCopiedTaskIds] = useState<Set<string>>(new Set());
  /** Source task whose Copy modal is currently mounted. Null = no modal. */
  const [copyingTask, setCopyingTask] = useState<Task | null>(null);
  /** When set, mounts TaskDetailSheet over the wizard so the user can
   *  inspect a task's full library detail without losing wizard state.
   *  Mirrors iOS BoardWizardTasksStepView's "Open in library" context-menu
   *  affordance. */
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);

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

  // Subtask counts for compounds (formerly composites + progress). Both
  // tabs render counts from the same `compound_children` source — the
  // legacy `taskStepCounts` and `compositeSubtaskCounts` collapse into
  // one map keyed by the parent compoundTaskId.
  const compoundChildCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const [compoundId, children] of Object.entries(library.compoundChildrenByCompound)) {
      counts[compoundId] = children.length;
    }
    return counts;
  }, [library.compoundChildrenByCompound]);

  // Alias kept for the existing call sites that still pass
  // `taskStepCounts` and `compositeSubtaskCounts` separately. Both
  // resolve to the same compound-children-derived count under the
  // unified model.
  const taskStepCounts = compoundChildCounts;
  const compositeSubtaskCounts = compoundChildCounts;

  // First-3 child titles + total subtask count, keyed by parent
  // compoundTaskId. Looks each child up via `taskMap` — under the unified
  // model, composites *are* tasks, so a single map handles both primitive
  // and nested compound children.
  const compositeLeafPreviews = useMemo(() => {
    const previews: Record<string, { titles: string[]; totalLeaves: number }> = {};
    for (const [compoundId, children] of Object.entries(library.compoundChildrenByCompound)) {
      // children are pre-sorted by childIndex in useTaskLibrary.
      const titles: string[] = [];
      for (const child of children.slice(0, 3)) {
        const t = library.taskMap[child.childTaskId];
        if (t) titles.push(t.title);
      }
      previews[compoundId] = { titles, totalLeaves: children.length };
    }
    return previews;
  }, [library.compoundChildrenByCompound, library.taskMap]);

  // Resolve a compound's primitive task leaves (flat — nested compounds
  // aren't boardable). Mirrors the legacy "taskId-only" semantic of
  // CompositeNode leaves.
  const compositeLeafTasks = useMemo(() => {
    const byCompound: Record<string, Task[]> = {};
    for (const [compoundId, children] of Object.entries(library.compoundChildrenByCompound)) {
      const tasks: Task[] = [];
      for (const child of children) {
        const t = library.taskMap[child.childTaskId];
        if (!t) continue;
        // Skip nested compounds — only flat primitive task leaves can be
        // placed directly on a board.
        if (t.type === TaskType.COMPOUND) continue;
        tasks.push(t);
      }
      byCompound[compoundId] = tasks;
    }
    return byCompound;
  }, [library.compoundChildrenByCompound, library.taskMap]);

  const visible = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    const matches = (title: string): boolean =>
      q.length === 0 || title.toLowerCase().includes(q);
    // Phase 6.Y — Timeboxed Tasks: hide expired tasks from every
    // wizard pool branch. Same default as the Tasks-tab list. There's
    // no "show expired" toggle here — the wizard is "tasks I might
    // want on this new board", and an expired task by definition
    // shouldn't be added to a fresh board. A user who genuinely needs
    // to backfill an expired task can re-extend its window from the
    // Tasks tab first.
    const notExpired = (t: Task): boolean => !isTaskExpired(t);

    // "From parent boards" surfaces tasks already placed on currently-
    // active longer-window parent boards (e.g. tasks on the active monthly
    // when creating a daily). Per Phase 6.1's locked design, selecting one
    // places the SAME task — completion is shared globally. Compounds
    // surfaced through this filter render in the primitives region too:
    // expanded leaves aren't useful here since the user is picking from
    // an existing curated set.
    if (activeFilter === 'from-parents') {
      const filtered = parentBoardTasks.filter((t) => notExpired(t) && matches(t.title));
      return { tasks: filtered, composites: [] };
    }

    // Under the unified compound model:
    //   - "Progress" filter = type=COMPOUND && isOrdered=true  → show in composites region
    //   - "Composite" filter (and the composites region) = type=COMPOUND && isOrdered!=true
    //   - "Normal"/"Counting" = primitives
    //   - "All" pool = primitives only (all compounds render in the composites region)
    const tasks =
      activeFilter === 'all'
        ? library.allTasks.filter((t) => notExpired(t) && t.type !== TaskType.COMPOUND && matches(t.title))
        : activeFilter === 'composite' || activeFilter === 'progress'
          ? []
          : library.allTasks.filter((t) => notExpired(t) && t.type === activeFilter && matches(t.title));

    // Composites region shows ALL compound tasks under "All" and type-specific
    // compound subsets under "Progress" / "Composite" filters so every compound
    // is reachable, selectable as a whole, and expandable into its leaves.
    const composites =
      activeFilter === 'all'
        ? library.allTasks.filter((t) => notExpired(t) && t.type === TaskType.COMPOUND && matches(t.title))
        : activeFilter === 'composite'
          ? library.allTasks.filter(
              (t) => notExpired(t) && t.type === TaskType.COMPOUND && t.isOrdered !== true && matches(t.title),
            )
          : activeFilter === 'progress'
            ? library.allTasks.filter(
                (t) => notExpired(t) && t.type === TaskType.COMPOUND && t.isOrdered === true && matches(t.title),
              )
            : [];

    return { tasks, composites };
  }, [library, activeFilter, searchQuery, parentBoardTasks]);

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
                {/* Suffix only in recurring mode — the spawn picks N
                    from the larger pool each window, so the user can
                    add more than N and the count is "min". One-off
                    boards keep the bare count. */}
                {isRecurring ? ' min' : null}
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

        {activeFilter !== 'from-board' && (
          <input
            type="search"
            className={styles.search}
            placeholder="Search your tasks…"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        )}

        <FilterTabs
          tabs={filterTabs}
          activeTab={activeFilter}
          onTabChange={(value) => {
            const next = value as TasksFilter;
            setActiveFilter(next);
            setExpandedCompositeId(null);
            // Re-entering the From-a-board flow resets the picker so
            // the user always lands in "pick a board" mode.
            if (next === 'from-board') {
              setPickedSourceBoardId(null);
            }
          }}
        />
      </div>

      {/* From-a-board flow — picker (no source) or grid (source picked) */}
      {activeFilter === 'from-board' ? (
        pickedSourceBoardId === null ? (
          <FromBoardPicker
            userId={userId}
            onPickBoard={(id) => setPickedSourceBoardId(id)}
          />
        ) : (
          <FromBoardGrid
            boardId={pickedSourceBoardId}
            userId={userId}
            selectedTaskIds={selectedTaskIds}
            copiedTaskIds={copiedTaskIds}
            onToggleSelection={handleToggle}
            onCopyTask={(task) => setCopyingTask(task)}
            onAddAllSubtasks={(_compoundTask, leafTaskIds) => {
              // Grid passes its already-resolved leaf ids (from the
              // SOURCE board's compound, which may not be in the
              // wizard's own library). Don't fall back to a parent-
              // side lookup — it would silently no-op for compounds
              // not yet in the library map.
              for (const leafId of leafTaskIds) {
                if (!selectedTaskIds.has(leafId)) {
                  onToggleSelection(leafId);
                }
              }
            }}
            onOpenInLibrary={(id) => setOpenedTaskInLibrary(id)}
            onChangeSource={() => setPickedSourceBoardId(null)}
            onTaskCreated={(task) => {
              // Derived counter — auto-add to selection like the list
              // flow does.
              if (!selectedTaskIds.has(task.id)) {
                onToggleSelection(task.id);
              }
            }}
          />
        )
      ) : visible.tasks.length === 0 && visible.composites.length === 0 ? (
        <div className={styles.emptyState}>
          {searchQuery.trim().length > 0
            ? `No tasks match "${searchQuery}".`
            : activeFilter === 'from-parents'
              ? 'No parent boards. Create a weekly/monthly/yearly board first.'
              : 'Library is empty. Tap "New task" to create one.'}
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
                  onContextMenu: (e) => {
                    e.preventDefault();
                    setRowContextMenu({ taskId: task.id, x: e.clientX, y: e.clientY });
                  },
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
            const isCompoundSelected = selectedTaskIds.has(ct.id);
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
                {/* Compound header row — two independent interaction zones:
                 *  1. Row body (select toggle) — adds/removes the compound task itself.
                 *  2. Disclosure button (chevron) — expands/collapses the leaf list. */}
                <div className={isCompoundSelected ? styles.rowSelectedWrap : styles.rowWrap}>
                  <button
                    type="button"
                    className={styles.row}
                    onClick={() => handleToggle(ct.id)}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      setRowContextMenu({ taskId: ct.id, x: e.clientX, y: e.clientY });
                    }}
                    aria-pressed={isCompoundSelected}
                  >
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
                  {/* Disclosure button — separate from the select tap target */}
                  <button
                    type="button"
                    className={styles.disclosureButton}
                    onClick={() =>
                      setExpandedCompositeId((prev) => (prev === ct.id ? null : ct.id))
                    }
                    aria-expanded={isExpanded}
                    aria-label={isExpanded ? 'Collapse subtasks' : 'Expand subtasks'}
                  >
                    <span
                      className={`${styles.chevron} ${isExpanded ? styles.chevronOpen : ''}`}
                      aria-hidden="true"
                    >
                      ▶
                    </span>
                  </button>
                </div>

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
                            onContextMenu: (e) => {
                              e.preventDefault();
                              setRowContextMenu({ taskId: leafTask.id, x: e.clientX, y: e.clientY });
                            },
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
        defaultTimeframe={currentTimeframe}
        defaultStartDate={currentStartDate}
        defaultEndDate={currentEndDate}
      />

      {rowContextMenu && (() => {
        const target = library.taskMap[rowContextMenu.taskId];
        if (!target) {
          return null;
        }
        const isCompound = target.type === TaskType.COMPOUND;
        const isCounting = target.type === TaskType.COUNTING
          && target.action != null && target.unit != null && target.maxCount != null;
        const isSelected = selectedTaskIds.has(target.id);
        const isCenter = centerTaskId === target.id;
        const isExpanded = expandedCompositeId === target.id;
        const leaves = compositeLeafTasks[target.id] ?? [];
        const close = (): void => setRowContextMenu(null);
        return (
          <RowContextMenu
            x={rowContextMenu.x}
            y={rowContextMenu.y}
            onClose={close}
            items={[
              {
                label: isSelected ? 'Remove from board' : 'Add to board',
                glyph: isSelected ? '−' : '+',
                action: () => { handleToggle(target.id); close(); },
              },
              ...(isCounting
                ? [{
                    label: 'Derive smaller version…',
                    glyph: '⇣',
                    action: () => {
                      setDerivingFromTask(target);
                      setDeriveMaxCountInput('');
                      setDeriveError(null);
                      close();
                    },
                  }]
                : []),
              ...(isCompound
                ? [
                    {
                      label: isExpanded ? 'Collapse subtasks' : 'Expand subtasks',
                      glyph: isExpanded ? '▲' : '▼',
                      action: () => {
                        setExpandedCompositeId(isExpanded ? null : target.id);
                        close();
                      },
                    },
                    ...(leaves.length > 0
                      ? [{
                          label: 'Add all subtasks to board',
                          glyph: '⧉',
                          action: () => {
                            for (const leaf of leaves) {
                              if (!selectedTaskIds.has(leaf.id)) {
                                handleToggle(leaf.id);
                              }
                            }
                            close();
                          },
                        }]
                      : []),
                    // Per-subtask quick-add — flat-listed so the user can
                    // pick a single leaf without expanding the row first.
                    // Already-selected leaves render as disabled checkmarks.
                    ...leaves.map((leaf) => {
                      const leafIsSelected = selectedTaskIds.has(leaf.id);
                      return {
                        label: leafIsSelected ? `✓ ${leaf.title}` : leaf.title,
                        glyph: leafIsSelected ? '·' : '+',
                        disabled: leafIsSelected,
                        action: () => {
                          if (!leafIsSelected) {
                            handleToggle(leaf.id);
                          }
                          close();
                        },
                      };
                    }),
                  ]
                : []),
              ...(centerTaskMode && isSelected && !isCompound
                ? [{
                    label: isCenter ? 'Unset as center task' : 'Set as center task',
                    glyph: isCenter ? '☆' : '★',
                    action: () => { handleCenterRadio(target.id); close(); },
                  }]
                : []),
              {
                label: 'Open in library',
                glyph: '↗',
                action: () => { setOpenedTaskInLibrary(target.id); close(); },
              },
            ]}
          />
        );
      })()}

      <TaskDetailSheet
        taskId={openedTaskInLibrary}
        onClose={() => setOpenedTaskInLibrary(null)}
        onOpenTask={(id) => setOpenedTaskInLibrary(id)}
      />

      {derivingFromTask && (
        <DeriveCounterModal
          source={derivingFromTask}
          maxCountInput={deriveMaxCountInput}
          onMaxCountChange={(v) => { setDeriveMaxCountInput(v); setDeriveError(null); }}
          error={deriveError}
          onCancel={() => setDerivingFromTask(null)}
          onSave={async () => {
            const parsed = parseInt(deriveMaxCountInput.trim(), 10);
            if (!Number.isFinite(parsed) || parsed <= 0) {
              setDeriveError('Max count must be a positive integer');
              return;
            }
            const action = (derivingFromTask.action ?? '').trim();
            const unit = (derivingFromTask.unit ?? '').trim();
            const title = `${action} ${parsed} ${unit}`;
            try {
              const newTask = await createTask(userId, {
                title,
                type: TaskType.COUNTING,
                action,
                unit,
                maxCount: parsed,
              });
              onTaskCreated(newTask);
              setDerivingFromTask(null);
            } catch (err) {
              setDeriveError(err instanceof Error ? err.message : 'Failed to save');
            }
          }}
        />
      )}

      {copyingTask && (
        <CopyTaskModal
          source={copyingTask}
          userId={userId}
          onCancel={() => setCopyingTask(null)}
          onCopied={(newTask) => {
            // Mark the source as "copied this session" for the
            // amber-tint indicator on the grid, and link the new
            // task into the wizard's selection.
            setCopiedTaskIds((prev) => {
              const next = new Set(prev);
              next.add(copyingTask.id);
              return next;
            });
            if (!selectedTaskIds.has(newTask.id)) {
              onToggleSelection(newTask.id);
            }
            setCopyingTask(null);
          }}
        />
      )}
    </div>
  );
}

// ─── Row renderer (shared between top-level tasks and expanded leaves) ────────

interface TaskRowProps {
  task: Task;
  isSelected: boolean;
  onToggle: () => void;
  /** Right-click handler — surfaces the same actions as a tap (toggle)
   *  plus center-task pinning when applicable. Mirrors iOS's
   *  `.contextMenu` long-press affordance. */
  onContextMenu?: (e: React.MouseEvent) => void;
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
  onContextMenu,
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
        onContextMenu={onContextMenu}
        aria-pressed={isSelected}
      >
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
  // Former Progress tasks: now compound + isOrdered=true. Show "N step(s)"
  // subtitle from compound children. Mirrors the iOS twin's
  // `case .compound where task.isOrdered == true` branch.
  if (task.type === TaskType.COMPOUND && task.isOrdered === true) {
    const n = taskStepCounts[task.id] ?? 0;
    if (n === 0) return '';
    return `${n} step${n === 1 ? '' : 's'}`;
  }
  return '';
}
