import { useMemo, useRef, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  Timeframe,
  TaskType,
  buildCounterFamilyMap,
  generateCounterTaskTitle,
  type BoardSource,
  type CompoundChild,
  type Pool,
  type Task,
} from '@oybc/shared';
import { fetchAllBoardTasks } from '../../db/operations';
import { createTask } from '../../db/operations/tasks';
import type { SourceSheetBoardEntry } from '../../db/operations/boardSources';
import {
  overlayCompoundChildrenWithStagedEdits,
  overlayTaskMapWithStagedEdits,
  patchesEqual,
  seedPatchForEditor,
  stagedNewChildPlaceholders,
  childPatchFromTask,
  type TaskEditPatch,
} from '../../db/taskEditPatch';
import { useParentBoardTasks } from '../../hooks';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { useBrowsableTasks, type TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import {
  computeCounterClashes,
  type SupplyInfoMap,
} from '../../pages/createHub/wizardSources';
import { RisoSectionLabel } from '../riso';
import { CopyTaskModal } from './CopyTaskModal';
import { DeriveCounterModal } from './DeriveCounterModal';
import { resolveDeriveLinkTarget } from './deriveCounterLink';
import { LibrarySheet } from './LibrarySheet';
import { PoolList } from './PoolList';
import { PoolRowEditor } from './PoolRowEditor';
import { RowContextMenu } from './RowContextMenu';
import { SourcePickerSheet } from './SourcePickerSheet';
import { SourceRow } from './SourceRow';
import { SpecialTaskPanel } from './SpecialTaskPanel';
import { mergeSuggestionPool } from './suggestionPool';
import { TasksPoolHeader } from './TasksPoolHeader';
import { WizardQuickAddRow } from './WizardQuickAddRow';
import { TaskDetailSheet } from '../TaskDetailSheet';
import styles from './BoardWizardTasksStep.module.css';

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
   * Board Sources P4 — the user's non-deleted pools, for the source
   * sheet's POOLS section. Loaded ONCE at `BoardWizardPage` (`usePools`)
   * and passed down rather than re-subscribed here.
   */
  pools: Pool[];
  /** Board Sources P4 — pulled sources in row order (`useBoardWizard.sources`). */
  sources: BoardSource[];
  /** Board Sources P4 — per-source display/supply cache. */
  supplyInfoBySourceId: SupplyInfoMap;
  /** Board Sources P4 — expanded row state (UI-only, never persisted). */
  expandedSourceIds: Set<string>;
  /** Board Sources P4 — post-exclude/post-filter available count per
   *  source (the range slider's N). */
  availableCountForSource: (sourceId: string) => number;
  /** Board Sources P4 — the header/gate capacity (sum of source maxes +
   *  hand-added, deduped). */
  capacity: number;
  /** Board Sources P4 — the source sheet's BOARDS rows (ACTIVE boards +
   *  squares/done counts), loaded by the page alongside `pools`. */
  sheetBoardEntries: SourceSheetBoardEntry[];
  onToggleSourceExpanded: (sourceId: string) => void;
  onRemoveSource: (sourceId: string) => void;
  onSetSourceFilter: (sourceId: string, filter: 'all' | 'todo') => void;
  onSetSourceRange: (sourceId: string, min: number, max: number | null) => void;
  onToggleSourceExclude: (sourceId: string, taskId: string) => void;
  onPullPoolSource: (poolId: string) => void;
  onPullBoardSource: (boardId: string) => void;

  /**
   * Web inline-editing port PR-2 — the wizard's staged inline task edits
   * (`useBoardWizard.stagedEdits`). Overlaid onto `effectiveTaskMap` /
   * `effectiveChildrenByCompound` so rows + the Step-3 preview reflect an
   * unsaved edit immediately.
   */
  stagedEdits: Map<string, TaskEditPatch>;
  /** Stage an inline edit; returns the previous patch (or `undefined`) for
   *  the Save toast's Undo. Routes to `useBoardWizard.stageEdit`. */
  onStageEdit: (taskId: string, patch: TaskEditPatch) => TaskEditPatch | undefined;
  /** Undo a staged edit. Routes to `useBoardWizard.revertEdit`. */
  onRevertEdit: (taskId: string, previous: TaskEditPatch | undefined) => void;
  /** Restore a removed task to the pool at its original index (re-adding
   *  its pending payload when non-`undefined`). Routes to
   *  `useBoardWizard.restoreToPool`. */
  onRestoreToPool: (taskId: string, index: number, payload: PendingTaskPayload | undefined) => void;

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
  sources,
  supplyInfoBySourceId,
  expandedSourceIds,
  availableCountForSource,
  capacity,
  sheetBoardEntries,
  onToggleSourceExpanded,
  onRemoveSource,
  onSetSourceFilter,
  onSetSourceRange,
  onToggleSourceExclude,
  onPullPoolSource,
  onPullBoardSource,
  stagedEdits,
  onStageEdit,
  onRevertEdit,
  onRestoreToPool,
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
    let merged = library.taskMap;
    if (pendingTasks && pendingTasks.size > 0) {
      merged = { ...merged };
      for (const payload of pendingTasks.values()) {
        merged[payload.task.id] = payload.task;
        for (const childTask of payload.childTasks) {
          merged[childTask.id] = childTask;
        }
      }
    }
    // Web inline-editing port PR-2 — overlay staged inline edits so rows +
    // the Step-3 preview reflect unsaved changes (the DB is untouched
    // until board create), then synthesize placeholder Task entries for
    // brand-new staged compound sub-tasks (no real Task row yet) so a
    // type-dependent lookup (e.g. the pool subtitle's "N with a goal"
    // subcount) resolves them. Mirrors iOS `effectiveTaskById`.
    merged = overlayTaskMapWithStagedEdits(merged, stagedEdits);
    if (stagedEdits.size > 0) {
      const placeholders = stagedNewChildPlaceholders(userId, stagedEdits);
      if (Object.keys(placeholders).length > 0) {
        merged = { ...merged, ...placeholders };
      }
    }
    return merged;
  }, [library.taskMap, pendingTasks, stagedEdits, userId]);
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

  // ── Inline pool-row editor (Web inline-editing port PR-2) ──────────────
  // At most one row open at a time.
  const [editingTaskId, setEditingTaskId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState<TaskEditPatch | null>(null);
  /** The draft as it was when the editor opened — used to tell whether the
   *  user actually changed anything on Discard (comparing against a fresh
   *  `patchFromTask` would never carry compound children, so it would
   *  falsely report "changed" for every compound). Mirrors iOS
   *  `editBaseline`. */
  const [editBaseline, setEditBaseline] = useState<TaskEditPatch | null>(null);
  const [toast, setToast] = useState<{ text: string; undo?: () => void } | null>(null);
  const toastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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
    let merged = library.compoundChildrenByCompound;
    if (pendingTasks && pendingTasks.size > 0) {
      merged = { ...merged };
      for (const payload of pendingTasks.values()) {
        if (payload.childLinks.length === 0) continue;
        // childLinks are pre-sorted by childIndex when assembled in
        // useCreateFormState. Use them as-is (matching how
        // useTaskLibrary returns library compoundChildren).
        merged[payload.task.id] = payload.childLinks;
      }
    }
    // Web inline-editing port PR-2 — a staged compound edit's KEPT
    // sub-tasks replace the base entry so the pool subtitle + expanded
    // preview reflect an unsaved add/remove/rename immediately. Mirrors
    // iOS `effectiveCompoundChildrenByCompound`.
    return overlayCompoundChildrenWithStagedEdits(merged, stagedEdits);
  }, [library.compoundChildrenByCompound, pendingTasks, stagedEdits]);

  // Board Sources P4 — the gate compares CAPACITY (the honest achievable
  // pool size since the counter-family rework) against the fillable cell
  // count, mirroring iOS.
  const isCountSatisfied = capacity >= tasksRequired;

  // Counter-family exclusivity (2026-09-08) — collisions visible in the
  // wizard pool, for the "shares a counter with 'X' · one per board" row
  // hints. Computed over the staged-overlaid task map so renames show.
  const counterClashByTaskId = useMemo<Map<string, string>>(() => {
    const famMap = buildCounterFamilyMap(Object.values(effectiveTaskMap));
    return computeCounterClashes(selectedTaskIds, famMap, effectiveTaskMap);
  }, [effectiveTaskMap, selectedTaskIds]);
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

  // ── Inline pool-row editor (Web inline-editing port PR-2) ──────────────

  function showToast(text: string, undo?: () => void): void {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    setToast({ text, undo });
    toastTimerRef.current = setTimeout(() => setToast(null), 6000);
  }

  /** Open the inline editor for a row. Closes any other open editor (only
   *  one at a time). Seeds the draft from the effective (staged-overlaid)
   *  task. Mirrors iOS `BoardWizardTasksStepView.openEditor`. */
  function openEditor(taskId: string): void {
    const task = effectiveTaskMap[taskId];
    if (!task) return;
    let draft: TaskEditPatch;
    const staged = stagedEdits.get(taskId);
    if (staged) {
      // Reopen: reuse the staged patch verbatim. `effectiveTaskMap`'s
      // overlay carries scalar edits (title/counting) but NOT compound
      // child edits, so reconstructing children here would silently
      // revert a prior sub-task rename/add/delete.
      draft = staged;
    } else {
      // First open: `seedPatchForEditor` blanks a Counting task's Title
      // field when it still matches its auto-generated form, so the title
      // keeps re-deriving as Action/Goal/Unit change in the editor.
      draft = seedPatchForEditor(task);
      if (task.type === TaskType.COMPOUND) {
        const links = [...(effectiveChildrenByCompound[taskId] ?? [])].sort(
          (a, b) => a.childIndex - b.childIndex,
        );
        draft = {
          ...draft,
          children: links
            .map((link) => effectiveTaskMap[link.childTaskId])
            .filter((t): t is Task => t !== undefined)
            .map((t) => childPatchFromTask(t)),
        };
      }
    }
    setEditDraft(draft);
    setEditBaseline(draft);
    setEditingTaskId(taskId);
  }

  /** Save the edit into the wizard's staged map (no DB write) and toast
   *  with undo to the previous snapshot. */
  function saveEdit(taskId: string): void {
    if (!editDraft) return;
    const previous = onStageEdit(taskId, editDraft);
    setEditingTaskId(null);
    // "edited" (not "updated") — the change is captured for this board's
    // creation, not yet written to the DB; don't overclaim persistence.
    const boardCount = taskBoardCounts[taskId] ?? 0;
    showToast(
      boardCount > 0
        ? `Staged · updates ${boardCount} board${boardCount === 1 ? '' : 's'} when you create`
        : 'Staged · saves when you create the board',
      () => onRevertEdit(taskId, previous),
    );
  }

  /** Discard the edit. If the draft differs from the task, toast "Edit
   *  discarded" with undo that reopens the row with the typing intact. */
  function discardEdit(taskId: string): void {
    if (!editDraft || !editBaseline) {
      setEditingTaskId(null);
      return;
    }
    // Compare against the draft as it opened — not a fresh `patchFromTask`,
    // which never carries compound children and so always reads as
    // "changed".
    const changed = !patchesEqual(editDraft, editBaseline);
    const keptDraft = editDraft;
    setEditingTaskId(null);
    if (changed) {
      showToast('Edit discarded', () => {
        setEditDraft(keptDraft);
        setEditBaseline(keptDraft);
        setEditingTaskId(taskId);
      });
    }
  }

  /** Remove a row immediately, closing its editor if open, and toast with
   *  undo that restores it at its original index. Keeps routing through
   *  `handleToggle` so the Bug #85 `pendingTasks` purge still fires. */
  function removeWithUndo(taskId: string): void {
    const index = poolOrder.indexOf(taskId);
    const name = effectiveTaskMap[taskId]?.title || 'task';
    // Capture the deferred (Bug #85) pending payload BEFORE removal purges
    // it, so Undo can restore it — otherwise the restored id can't resolve
    // and the board under-fills. `undefined` for library tasks.
    const payload = pendingTasks?.get(taskId);
    if (editingTaskId === taskId) setEditingTaskId(null);
    handleToggle(taskId);
    showToast(`Removed "${name}"`, () =>
      onRestoreToPool(taskId, index === -1 ? poolOrder.length : index, payload),
    );
  }

  return (
    <div className={styles.container}>
      {/* 1. Pool header card */}
      <TasksPoolHeader
        capacity={capacity}
        tasksRequired={tasksRequired}
        isRecurring={isRecurring}
        centerTaskMode={centerTaskMode}
        centerSatisfied={isCenterSatisfied}
      />


      {/* 2. "Add tasks" — quick-add row + special-type panel */}
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

      {/* 3. "Add a pool or board" — dashed entry row + sheet (frames
          2a/2c/5c). Sheet taps toggle: pull when absent, remove when
          pulled (mirrors iOS's sheet wiring). */}
      <SourcePickerSheet
        pools={pools}
        boardEntries={sheetBoardEntries}
        pulledSourceIds={useMemo(() => new Set(sources.map((s) => s.sourceId)), [sources])}
        onTogglePool={(poolId) =>
          sources.some((s) => s.sourceId === poolId)
            ? onRemoveSource(poolId)
            : onPullPoolSource(poolId)
        }
        onToggleBoard={(boardId) =>
          sources.some((s) => s.sourceId === boardId)
            ? onRemoveSource(boardId)
            : onPullBoardSource(boardId)
        }
      />

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
        centerTaskMode={centerTaskMode}
        centerTaskId={centerTaskId}
        onCenterClick={handleCenterRadio}
        onRemove={removeWithUndo}
        onContextMenu={(taskId, x, y) => setRowContextMenu({ taskId, x, y })}
        editingTaskId={editingTaskId}
        onEdit={openEditor}
        editor={(task) =>
          editDraft && (
            <PoolRowEditor
              taskType={task.type}
              draft={editDraft}
              onDraftChange={setEditDraft}
              onSave={() => saveEdit(task.id)}
              onDiscard={() => discardEdit(task.id)}
              usedOnBoardCount={taskBoardCounts[task.id] ?? 0}
            />
          )
        }
        counterClashByTaskId={counterClashByTaskId}
        countOverride={capacity}
        leadingRows={
          sources.length > 0
            ? sources.map((source) => (
                <SourceRow
                  key={source.sourceId}
                  source={source}
                  supply={
                    supplyInfoBySourceId[source.sourceId] ?? {
                      displayName: '',
                      rawSupplyTaskIds: [],
                      doneTaskIds: new Set<string>(),
                    }
                  }
                  availableCount={availableCountForSource(source.sourceId)}
                  isExpanded={expandedSourceIds.has(source.sourceId)}
                  taskById={effectiveTaskMap}
                  onToggleExpanded={() => onToggleSourceExpanded(source.sourceId)}
                  onRemove={() => onRemoveSource(source.sourceId)}
                  onSetFilter={(filter) => onSetSourceFilter(source.sourceId, filter)}
                  onSetRange={(min, max) => onSetSourceRange(source.sourceId, min, max)}
                  onToggleExclude={(taskId) => onToggleSourceExclude(source.sourceId, taskId)}
                  counterClashByTaskId={counterClashByTaskId}
                />
              ))
            : undefined
        }
      />

      {toast && (
        <div className={styles.toast} role="status">
          <span className={styles.toastText}>{toast.text}</span>
          {toast.undo && (
            <button
              type="button"
              className={styles.toastUndo}
              onClick={() => {
                if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
                const undo = toast.undo;
                setToast(null);
                undo?.();
              }}
            >
              UNDO
            </button>
          )}
        </div>
      )}

      {/* Footer — actions */}
      <div className={styles.footer}>
        {/* Visible dead-Next reason — the tooltip alone is invisible on
            touch, and a quietly greyed-out Next reads as "broken". */}
        {!canAdvance && (
          <span
            className={!isCountSatisfied ? styles.footerMessageCore : styles.footerMessage}
          >
            {!isCountSatisfied
              ? `! Add ${tasksRequired - capacity} more`
              : 'Mark one selected task as the center.'}
          </span>
        )}
        <button type="button" className={styles.backButton} onClick={onBack}>
          ‹ Back
        </button>
        <button
          type="button"
          // Board Creation Split (web PR C) — accent tracks the wizard's
          // fixed mode: red one-off / blue recurring.
          className={`${styles.nextButton} ${isRecurring ? styles.nextButtonBlue : ''}`}
          onClick={onNext}
          disabled={!canAdvance}
          title={
            !isCountSatisfied
              ? `${tasksRequired - capacity} more to fill the board`
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
              // Web inline-editing port PR-2 — "Edit task…" is FIRST,
              // mirroring the design handoff. Only meaningful for a
              // pooled (selected), non-Achievement task — Achievement
              // tasks are always read-only here (edited on the Tasks
              // page), and an unselected library row has nothing staged
              // to edit yet.
              ...(isSelected && target.type !== TaskType.ACHIEVEMENT
                ? [{
                    label: 'Edit task…',
                    glyph: '✎',
                    action: () => { openEditor(target.id); close(); },
                  }]
                : []),
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

    </div>
  );
}
