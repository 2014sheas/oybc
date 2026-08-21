import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  Timeframe,
  TaskType,
  generateCounterTaskTitle,
  type CompoundChild,
  type Pool,
  type Task,
} from '@oybc/shared';
import { fetchAllBoardTasks } from '../../db/operations';
import { createTask } from '../../db/operations/tasks';
import { upsertCoreBoardDefault } from '../../db/operations/coreBoardDefaults';
import {
  useCoreBoardDefault,
  useParentBoardTasks,
  useRecurringBoardTemplates,
} from '../../hooks';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { useBrowsableTasks, type TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { PoolEditSheet } from '../pools/PoolEditSheet';
import { RisoChip, RisoSectionLabel } from '../riso';
import { CopyTaskModal } from './CopyTaskModal';
import { DeriveCounterModal } from './DeriveCounterModal';
import { resolveDeriveLinkTarget } from './deriveCounterLink';
import { LibrarySheet } from './LibrarySheet';
import { PoolList } from './PoolList';
import { RowContextMenu } from './RowContextMenu';
import { SpecialTaskPanel } from './SpecialTaskPanel';
import { mergeSuggestionPool } from './suggestionPool';
import { TasksPoolHeader } from './TasksPoolHeader';
import { WizardQuickAddRow } from './WizardQuickAddRow';
import { TaskDetailSheet } from '../TaskDetailSheet';
import {
  classifyChipProvenance,
  computeCoreFloorGate,
  isCorePoolDefaultSaved,
} from '../../pages/createHub/poolPullLogic';
import styles from './BoardWizardTasksStep.module.css';

/**
 * P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 6 "Core-board setup") — plain cadence words for the
 * "Start every &lt;Timeframe&gt; board with 'X'" checkbox label. No
 * shared helper produces this exact shape (`formatTimeframeLabel` formats
 * a WINDOW — "Today" / "Week of…" — and `formatRecurringCadence` formats
 * a sentence — "Every day"); every other web surface that needs a plain
 * cadence word (`CoreBoardBrowserPage`, `CoreBoardsSection`, `CoreStrip`,
 * `RecurringTemplateRow`, …) already duplicates its own local map, so this
 * follows the same established precedent rather than introducing a new
 * shared export for a single UI string.
 */
const CORE_CADENCE_LABEL: Partial<Record<Timeframe, string>> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
};

export interface BoardWizardTasksStepProps {
  /** User's full task + composite library (from `useTaskLibrary`). */
  library: TaskLibrary;

  /** Currently-selected task ids — controlled by the wizard. */
  selectedTaskIds: Set<string>;
  /**
   * Web inline-editing port PR-1 — insertion order of the pool
   * (`useBoardWizard.poolOrder`). The pool list renders in this order,
   * never re-sorted, so a task keeps its position across the session (a
   * later PR's inline rename must not reshuffle the list).
   */
  poolOrder: string[];
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
   *  wizard will write on the board. Threaded into quick-add / the
   *  special-type panel so any new task created from inside the wizard
   *  inherits the same timeboxed window as its parent board. */
  currentStartDate?: string;
  currentEndDate?: string;
  /** Fired after a non-composite task is created — the wizard should
   *  auto-add the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /**
   * Bug #85 — Deferred-persist supplemental callback. When provided, the
   * quick-add row + special-type panel enable deferPersist mode so no DB
   * write occurs at creation time. The full pending payload (task + any
   * compound child tasks + links) is passed here so the wizard can store
   * it for atomic board-save later. Called alongside `onTaskCreated` for
   * every deferred create.
   */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /**
   * Bug #85 — In-memory pending tasks owned by the wizard. Passed here
   * so the Tasks step can surface newly-created (not-yet-persisted)
   * tasks in the visible list as selected rows. Without this, the user
   * creates a task via the special-type panel and it appears to vanish
   * until the board is saved (because it's not yet in the DB that the
   * live library query reads from). When omitted, pending tasks won't be
   * shown in the list (safe fallback — the count is still correct).
   */
  pendingTasks?: Map<string, PendingTaskPayload>;
  /** Fired after a compound (formerly composite) task is created — the
   *  wizard should reload the library so the compound shows up under
   *  filters. Under the unified model composites are Tasks, so the
   *  callback uses Task. */
  onCompositeCreated: (task: Task) => void;

  /**
   * P3 (Task Pools + Recurring Boards Rework) — the user's non-deleted
   * pools, for the "PULL IN A POOL" toggle-chip card. Loaded ONCE at
   * `BoardWizardPage` (`usePools`) and passed down rather than
   * re-subscribed here, mirroring the `PoolsBrowse`/`TasksPage`
   * "load once, pass down" precedent (avoids a second concurrent
   * `usePools` live query).
   */
  pools: Pool[];
  /** P3 — pool ids currently pulled into the selection, in pull order. */
  pulledPoolIds: string[];
  /** P3 — toggle a pool ON: unions its resolvable tasks into the selection. */
  onPullPool: (poolId: string) => void;
  /** P3 — toggle a pool OFF: removes its non-manual, non-still-supplied tasks. */
  onUntogglePool: (poolId: string) => void;
  /** P3 — provenance label ("from X" / "added by hand") for every
   *  currently-selected task id. */
  taskProvenance: Map<string, string>;
  /** P3 — task ids explicitly hand-added this session (quick-add, the
   *  special-type panel, or picking an existing library task) as opposed
   *  to pool-/default-sourced. Drives the P5 core-setup chip strip's plain
   *  vs. blue-removable classification (see `classifyChipProvenance`). */
  manualTaskIds: Set<string>;

  /**
   * P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
   * §Surfaces item 6 "Core-board setup") — true when this wizard session
   * is creating/resuming a core (recurring-timeframe) board. Gates the
   * core-setup-only UI: the "Start with a pool — optional" pool-pull
   * header text, the selected-tasks chip strip (plain vs. hand-added
   * blue-removable), the "Start every &lt;Timeframe&gt; board with 'X'"
   * checkbox, and the red "Add N more" floor-gate copy. Never changes
   * behavior for a non-core wizard session.
   */
  isCore: boolean;

  /** Navigates to the previous wizard step. */
  onBack: () => void;
  /** Navigates to the next wizard step. Disabled when validation fails. */
  onNext: () => void;
}

/**
 * BoardWizardTasksStep — Step 2 of the board-creation wizard.
 *
 * Pool-first restructure (Web inline-editing port PR-1 — the RESTRUCTURE
 * half; the inline row editor is PR-2). Order (mirrors iOS
 * `BoardWizardTasksStepView` so the two platforms stop diverging):
 *
 *   1. `TasksPoolHeader` — kicker, N/required count, progress bar, note.
 *   2. "PULL IN A POOL" card (+ P5 core-setup section) — unchanged.
 *   3. "Add tasks" — quick-add row + `SpecialTaskPanel`.
 *   4. `LibrarySheet` — dashed entry button → bottom sheet. The library
 *      (search, filters, from-a-board, compound expand) lives ENTIRELY
 *      inside the sheet now; it's no longer primary content.
 *   5. `PoolList` — the tasks actually on this board, in `poolOrder`.
 *      Each row's ✎ slot is a disabled PR-1 stub (PR-2 wires the inline
 *      editor); the slot is still rendered so the trailing gutter's
 *      column alignment doesn't shift when PR-2 lands.
 *   6. "Save these N as a new pool…" (P3) — unchanged.
 *   7. Footer — Back / Next.
 *
 * Cross-cutting overlays (right-click menu, derive-smaller modal, copy
 * modal, task-detail sheet, save-as-pool sheet) stay owned here since the
 * SAME `RowContextMenu` instance now serves both `LibrarySheet` and
 * `PoolList` rows.
 *
 * The component is controlled — `selectedTaskIds`, `poolOrder`,
 * `centerTaskId`, and navigation callbacks are owned by the wizard's
 * state controller. Internal state here is limited to the shared overlay
 * modals; `LibrarySheet`/`SpecialTaskPanel`/`PoolList` each own their own
 * UI-local state (search, filters, expand, panel-open).
 */
export function BoardWizardTasksStep({
  library,
  selectedTaskIds,
  poolOrder,
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
  onPendingCreated,
  pendingTasks,
  onCompositeCreated,
  pools,
  pulledPoolIds,
  onPullPool,
  onUntogglePool,
  taskProvenance,
  manualTaskIds,
  isCore,
  onBack,
  onNext,
}: BoardWizardTasksStepProps): React.ReactElement {
  // Bug #85 — Build a merged task map that includes in-memory pending
  // tasks alongside the live library so they appear in the list as
  // selected rows. Pending tasks won't be in the Dexie live query yet.
  //
  // The map includes BOTH the pending parent task AND any pending
  // childTasks (inline-created compound children). Without the children,
  // leaf previews / expanded leaves for a pending compound would fail
  // to resolve child titles via taskMap lookup.
  const effectiveTaskMap = useMemo<Record<string, Task>>(() => {
    if (!pendingTasks || pendingTasks.size === 0) return library.taskMap;
    const merged = { ...library.taskMap };
    for (const payload of pendingTasks.values()) {
      merged[payload.task.id] = payload.task;
      for (const childTask of payload.childTasks) {
        merged[childTask.id] = childTask;
      }
    }
    return merged;
  }, [library.taskMap, pendingTasks]);
  const browsableTasks = useBrowsableTasks(library.allTasks, library.childToParents);
  const effectiveAllTasks = useMemo<Task[]>(() => {
    // Browse the draft-filtered set (hides other drafts' wizard-orphans), but
    // always merge THIS session's in-memory pending tasks so the just-created
    // ones still appear.
    if (!pendingTasks || pendingTasks.size === 0) return browsableTasks;
    const pendingArr = Array.from(pendingTasks.values()).map((p) => p.task);
    // Deduplicate: library tasks first, pending tasks fill any gaps.
    const ids = new Set(browsableTasks.map((t) => t.id));
    return [...browsableTasks, ...pendingArr.filter((t) => !ids.has(t.id))];
  }, [browsableTasks, pendingTasks]);

  // R1 counters refresh (review fix) — unfiltered (non-browsable-filtered)
  // task pool + this session's pending tasks, used ONLY as the counter-link
  // suggestion pool passed to `SpecialTaskPanel`. Unlike `effectiveAllTasks`
  // (built from `browsableTasks` for pickers/autocomplete), this uses
  // `library.allTasks` so goal-less hub-born counters — which
  // `computeBrowsableTasks` excludes — still surface a link suggestion in
  // the wizard, AND so a same-session pending counter (created earlier in
  // this wizard visit, not yet persisted) is matchable too. Mirrors iOS
  // `BoardWizardTasksStepView.effectiveSuggestionPool`.
  const effectiveSuggestionPool = useMemo<Task[]>(
    () => mergeSuggestionPool(library.allTasks, pendingTasks),
    [library.allTasks, pendingTasks],
  );

  // Reactive list of unique tasks placed on currently-active parent boards.
  // Always called (hooks rule) but returns [] when the timeframe has no
  // parents, so it's effectively a no-op for yearly/custom.
  const parentBoardTasks = useParentBoardTasks(userId, currentTimeframe);

  /** Right-click context menu state. Null when no menu is open. Stores
   *  the target task's id + cursor position; actions are derived at render
   *  time from the task's type (compound vs primitive). Shared by both
   *  `LibrarySheet` and `PoolList` rows. */
  const [rowContextMenu, setRowContextMenu] = useState<
    { taskId: string; x: number; y: number } | null
  >(null);
  /** Source counting task + draft new maxCount for the "derive smaller
   *  version" quick action. Null when the deriver modal is closed. */
  const [derivingFromTask, setDerivingFromTask] = useState<Task | null>(null);
  const [deriveMaxCountInput, setDeriveMaxCountInput] = useState('');
  const [deriveError, setDeriveError] = useState<string | null>(null);
  /** Task ids copied via the From-a-board grid's `⎘ Add a copy…`
   *  this session (surfaced inside `LibrarySheet`). Used to render the
   *  amber-tint indicator on source squares whose original we've already
   *  copied. Cleared on remount (session-scoped). */
  const [copiedTaskIds, setCopiedTaskIds] = useState<Set<string>>(new Set());
  /** Source task whose Copy modal is currently mounted. Null = no modal. */
  const [copyingTask, setCopyingTask] = useState<Task | null>(null);
  /** When set, mounts TaskDetailSheet over the wizard so the user can
   *  inspect a task's full library detail without losing wizard state.
   *  Mirrors iOS BoardWizardTasksStepView's "Open in library" context-menu
   *  affordance. */
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);
  /** P3 — "Save these N as a new pool…" affordance. Opens `PoolEditSheet`
   *  in create mode, pre-seeded from the current selection. */
  const [showSaveAsPoolSheet, setShowSaveAsPoolSheet] = useState(false);
  // P3 — recurring-board templates, needed only for `PoolEditSheet`'s
  // deck-preview-floor computation (mirrors `PoolsBrowse`'s call site).
  const recurringTemplatesForPoolSheet = useRecurringBoardTemplates(userId);

  // P5 — the current timeframe's CoreBoardDefault, ONLY looked up when
  // this is a core-setup session (isCore). Backs the "Start every
  // <Timeframe> board with 'X'" checkbox's derived checked state. Tri-
  // state (`undefined`/loading, `null`/none, value) — treated as "no
  // saved default" (`[]`) until it resolves, so the checkbox starts
  // unchecked rather than flashing checked.
  const coreBoardDefault = useCoreBoardDefault(
    isCore ? userId : undefined,
    isCore ? currentTimeframe : undefined,
  );
  const savedCorePoolIds = coreBoardDefault?.corePoolIds ?? [];
  const isCoreDefaultSaved = isCorePoolDefaultSaved(pulledPoolIds, savedCorePoolIds);
  const [coreDefaultBusy, setCoreDefaultBusy] = useState(false);

  /**
   * P5 — "Start every <Timeframe> board with 'X'" checkbox handler.
   * Writes `corePoolIds` ONLY (never `coreDefaultTaskIds`, which is
   * P7-authored-only) — `upsertCoreBoardDefault`'s partial-update
   * semantics leave any existing `coreDefaultTaskIds` untouched. This is
   * a point-in-time snapshot write, not a live binding: `pulledPoolIds`
   * can keep changing afterward via further pool toggling without
   * re-writing the saved default. Unchecking clears `corePoolIds` to
   * `[]` — a deliberate, symmetric "stop starting every board with
   * this" action (a checkbox that can't be unchecked isn't a checkbox).
   */
  async function handleToggleCoreDefault(checked: boolean): Promise<void> {
    setCoreDefaultBusy(true);
    try {
      await upsertCoreBoardDefault(userId, currentTimeframe, {
        corePoolIds: checked ? pulledPoolIds : [],
      });
    } finally {
      setCoreDefaultBusy(false);
    }
  }

  const coreCadenceLabel = CORE_CADENCE_LABEL[currentTimeframe] ?? currentTimeframe;
  const coreDefaultCheckboxLabel = useMemo(() => {
    if (pulledPoolIds.length === 1) {
      const pool = pools.find((p) => p.id === pulledPoolIds[0]);
      const name = pool?.name ?? 'this pool';
      return `Start every ${coreCadenceLabel} board with "${name}"`;
    }
    return `Start every ${coreCadenceLabel} board with these pools`;
  }, [pulledPoolIds, pools, coreCadenceLabel]);

  const coreFloorGate = useMemo(
    () => computeCoreFloorGate(selectedTaskIds.size, tasksRequired),
    [selectedTaskIds, tasksRequired],
  );

  // Usage-hint data — "N boards" / "unused" — shared by LibrarySheet and
  // PoolList rows. Requires a live query since `useTaskLibrary` doesn't
  // expose boardTasks.
  const allBoardTasks = useLiveQuery(() => fetchAllBoardTasks(), []) ?? [];

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

  // Bug #85 — Merge in-memory pending `childLinks` with the live
  // `compoundChildrenByCompound` map so a newly-created (not-yet-
  // persisted) compound shows the right step count + leaf previews +
  // expandable leaves. Without this, a pending compound rendered with 0
  // steps and couldn't expand.
  const effectiveChildrenByCompound = useMemo<Record<string, CompoundChild[]>>(() => {
    if (!pendingTasks || pendingTasks.size === 0) {
      return library.compoundChildrenByCompound;
    }
    const merged: Record<string, CompoundChild[]> = {
      ...library.compoundChildrenByCompound,
    };
    for (const payload of pendingTasks.values()) {
      if (payload.childLinks.length === 0) continue;
      // childLinks are pre-sorted by childIndex when assembled in
      // useCreateFormState. Use them as-is (matching how
      // useTaskLibrary returns library compoundChildren).
      merged[payload.task.id] = payload.childLinks;
    }
    return merged;
  }, [library.compoundChildrenByCompound, pendingTasks]);

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
      {/* 1. Pool header card */}
      <TasksPoolHeader
        selectedCount={selectedCount}
        tasksRequired={tasksRequired}
        isRecurring={isRecurring}
        centerTaskMode={centerTaskMode}
        centerSatisfied={isCenterSatisfied}
      />

      {/* 2. "PULL IN A POOL" card (P3) + P5 core-setup section */}
      <div className={styles.header}>
        <div className={styles.poolPullCard}>
          <span className={styles.poolPullKicker}>
            {isCore ? 'Start with a pool — optional' : 'Pull in a pool'}
          </span>
          {pools.length === 0 ? (
            <p className={styles.poolPullEmpty}>You don&apos;t have any pools yet.</p>
          ) : (
            <div className={styles.poolPullChips} role="group" aria-label="Pull in a pool">
              {pools.map((pool) => {
                const isPulled = pulledPoolIds.includes(pool.id);
                return (
                  <RisoChip
                    key={pool.id}
                    on={isPulled}
                    onClick={() => (isPulled ? onUntogglePool(pool.id) : onPullPool(pool.id))}
                  >
                    {pool.name}
                  </RisoChip>
                );
              })}
            </div>
          )}
        </div>

        {isCore && (
          <div className={styles.coreDefaultsSection}>
            {selectedTaskIds.size > 0 && (
              <div className={styles.coreChipStrip} role="group" aria-label="Tasks in this board">
                {poolOrder.map((taskId) => {
                  const task = effectiveTaskMap[taskId];
                  const title = task?.title || '(untitled task)';
                  const kind = classifyChipProvenance(taskId, manualTaskIds);
                  if (kind === 'manual') {
                    return (
                      <span key={taskId} className={styles.coreChipManual}>
                        {title}
                        <button
                          type="button"
                          className={styles.coreChipRemove}
                          onClick={() => handleToggle(taskId)}
                          aria-label={`Remove ${title} from this board`}
                        >
                          ✕
                        </button>
                      </span>
                    );
                  }
                  return (
                    <span key={taskId} className={styles.coreChipPlain}>
                      {title}
                    </span>
                  );
                })}
              </div>
            )}

            {pulledPoolIds.length > 0 && (
              <label className={styles.coreDefaultRow}>
                <input
                  type="checkbox"
                  className={styles.coreDefaultCheckbox}
                  checked={isCoreDefaultSaved}
                  disabled={coreDefaultBusy}
                  onChange={(e) => void handleToggleCoreDefault(e.target.checked)}
                />
                <span>{coreDefaultCheckboxLabel}</span>
              </label>
            )}
          </div>
        )}
      </div>

      {/* 3. "Add tasks" — quick-add row + special-type panel */}
      <div className={styles.addTasksSection}>
        <RisoSectionLabel>Add tasks</RisoSectionLabel>

        <div className={styles.quickAddCard}>
          <WizardQuickAddRow
            userId={userId}
            currentTimeframe={currentTimeframe}
            currentStartDate={currentStartDate}
            currentEndDate={currentEndDate}
            onTaskCreated={onTaskCreated}
            onPendingCreated={onPendingCreated}
            // Library polling (owner decision 2026-07-21): the SAME
            // browsable+pending set the library sheet / compound
            // autocomplete already use, so a typed title that matches an
            // existing task offers a reuse match instead of a duplicate.
            libraryTasks={effectiveAllTasks}
            selectedIds={selectedTaskIds}
            onExistingTaskPicked={onTaskCreated}
          />
        </div>

        <SpecialTaskPanel
          userId={userId}
          defaultTimeframe={currentTimeframe}
          defaultStartDate={currentStartDate}
          defaultEndDate={currentEndDate}
          onTaskCreated={onTaskCreated}
          onPendingCreated={onPendingCreated}
          onCompoundCreated={onCompositeCreated}
          suggestionPool={effectiveSuggestionPool}
        />
      </div>

      {/* 4. Library entry button → bottom sheet */}
      <LibrarySheet
        effectiveAllTasks={effectiveAllTasks}
        childTaskIds={library.childTaskIds}
        effectiveChildrenByCompound={effectiveChildrenByCompound}
        effectiveTaskMap={effectiveTaskMap}
        taskBoardCounts={taskBoardCounts}
        selectedTaskIds={selectedTaskIds}
        onToggleSelection={handleToggle}
        centerTaskMode={centerTaskMode}
        centerTaskId={centerTaskId}
        onCenterClick={handleCenterRadio}
        taskProvenance={taskProvenance}
        onContextMenu={(taskId, x, y) => setRowContextMenu({ taskId, x, y })}
        onDeriveRequested={(task) => {
          setDerivingFromTask(task);
          setDeriveMaxCountInput('');
          setDeriveError(null);
        }}
        onOpenInLibrary={(id) => setOpenedTaskInLibrary(id)}
        onCopyTaskRequested={(task) => setCopyingTask(task)}
        copiedTaskIds={copiedTaskIds}
        userId={userId}
        currentTimeframe={currentTimeframe}
        parentBoardTasks={parentBoardTasks}
      />

      {/* 5. Pool list — the tasks actually on this board */}
      <PoolList
        poolOrder={poolOrder}
        effectiveTaskMap={effectiveTaskMap}
        effectiveChildrenByCompound={effectiveChildrenByCompound}
        taskBoardCounts={taskBoardCounts}
        taskProvenance={taskProvenance}
        centerTaskMode={centerTaskMode}
        centerTaskId={centerTaskId}
        onCenterClick={handleCenterRadio}
        onRemove={handleToggle}
        onContextMenu={(taskId, x, y) => setRowContextMenu({ taskId, x, y })}
      />

      {/* P3 — "Save these N as a new pool…" — mints a Pool from the
          current selection, independent of the board. */}
      <button
        type="button"
        className={styles.savePoolButton}
        disabled={selectedTaskIds.size === 0}
        onClick={() => setShowSaveAsPoolSheet(true)}
      >
        Save these {selectedTaskIds.size} as a new pool…
      </button>

      {/* Footer — actions */}
      <div className={styles.footer}>
        {/* Visible dead-Next reason — the tooltip alone is invisible on
            touch, and a quietly greyed-out Next reads as "broken". */}
        {!canAdvance && (
          <span
            className={
              isCore && !isCountSatisfied ? styles.footerMessageCore : styles.footerMessage
            }
          >
            {!isCountSatisfied
              ? isCore
                ? coreFloorGate.message
                : (() => {
                    const n = tasksRequired - selectedCount;
                    return `Pick ${n} more task${n === 1 ? '' : 's'} to continue (${tasksRequired}${isRecurring ? ' minimum' : ''} needed).`;
                  })()
              : 'Mark one selected task as the center.'}
          </span>
        )}
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

      {rowContextMenu && (() => {
        // Use effectiveTaskMap (library + this-session pending tasks), not
        // library.taskMap — otherwise right-clicking a just-created pending
        // task row finds no target and silently opens no menu. Pending tasks
        // are valid right-click targets (they're addable to the board).
        const target = effectiveTaskMap[rowContextMenu.taskId];
        if (!target) {
          return null;
        }
        const isCompound = target.type === TaskType.COMPOUND;
        const isCounting = target.type === TaskType.COUNTING
          && target.action != null && target.unit != null && target.maxCount != null;
        const isSelected = selectedTaskIds.has(target.id);
        const isCenter = centerTaskId === target.id;
        const leaves = (effectiveChildrenByCompound[target.id] ?? [])
          .map((c) => effectiveTaskMap[c.childTaskId])
          .filter((t): t is Task => t !== undefined && t.type !== TaskType.COMPOUND);
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
                    // pick a single leaf without opening the library sheet.
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
              ...(centerTaskMode && isSelected
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
              setDeriveError('Goal must be a positive integer');
              return;
            }
            const action = (derivingFromTask.action ?? '').trim();
            const unit = (derivingFromTask.unit ?? '').trim();
            const title = generateCounterTaskTitle(action, parsed, unit);
            // R1 counters refresh — "Derive smaller version" must produce a
            // LINKED task, not a standalone duplicate (the modal's own copy
            // already promises "same counter, lower goal"). See
            // `resolveDeriveLinkTarget` for the source-resolution rule.
            // `effectiveTaskMap` (already loaded for this component's row
            // rendering) resolves the root task synchronously when
            // `derivingFromTask` is itself derived.
            const linkTarget = resolveDeriveLinkTarget(
              derivingFromTask,
              effectiveTaskMap[derivingFromTask.sharedCounterId ?? derivingFromTask.id],
            );
            try {
              const newTask = await createTask(userId, {
                title,
                type: TaskType.COUNTING,
                action,
                unit,
                maxCount: parsed,
                sharedCounterId: linkTarget.sharedCounterId,
                baseline: linkTarget.baseline,
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

      {/* P3 — "Save these N as a new pool…" sheet. Create mode only
          (no `pool` prop), pre-seeded from the current selection minus
          any still-pending (not-yet-persisted) tasks — a Pool.taskIds
          reference can't point at a task that doesn't exist in the DB
          yet. Independent of the board: saving here never mutates
          `pulledPoolIds`/`selectedTaskIds`. */}
      {showSaveAsPoolSheet && (
        <PoolEditSheet
          userId={userId}
          templates={recurringTemplatesForPoolSheet}
          allTasks={library.allTasks}
          browsableTasks={browsableTasks}
          initialTaskIds={poolOrder.filter(
            (id) => !(pendingTasks?.has(id) ?? false),
          )}
          onClose={() => setShowSaveAsPoolSheet(false)}
          onSaved={() => setShowSaveAsPoolSheet(false)}
          onDeleted={() => setShowSaveAsPoolSheet(false)}
        />
      )}
    </div>
  );
}
