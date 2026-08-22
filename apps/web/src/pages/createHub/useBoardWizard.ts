import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useCoreBoardDefault, useTemplateMix } from '../../hooks';
import {
  CenterSquareType,
  Timeframe,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  type Board,
  type BoardTask,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
  type UserPreferences,
  type WeekStartDay,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import {
  applyCoreBoardDefaultPrefill,
  applyManualBookkeepingOnDeselect,
  applyManualBookkeepingOnSelect,
  applyPullPool,
  applyUntogglePool,
  deriveTaskProvenance,
  syncPoolOrder,
} from './poolPullLogic';
import { resolveInitialWizardTimeframe } from './wizardTimeframeSeed';

/** Stable empty fallback so a caller that omits `tasksById` doesn't cause
 *  a new object identity (and downstream memo churn) every render. */
const EMPTY_TASKS_BY_ID: Record<string, Task> = {};
/** Stable empty fallback for a caller that omits `pools`. */
const EMPTY_POOLS: Pool[] = [];

/** A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate. */
export type WizardStep = 1 | 2 | 3;

/**
 * Returns the number of pool tasks the chosen geometry requires.
 *
 * - Even-sized boards (no center concept): `size²`.
 * - Odd-sized boards with FREE center: `size² - 1`
 *   (the center cell is auto-filled, doesn't consume a task).
 * - Odd-sized boards with NONE: `size²` (no special center).
 * - Odd-sized boards with CHOSEN: `size²` (one of the selections IS
 *   the center).
 */
export function tasksNeededFor(size: 3 | 4 | 5, centerType: CenterSquareType): number {
  const isOdd = size % 2 !== 0;
  const hasReservedCenter = isOdd && centerType === CenterSquareType.FREE;
  return size * size - (hasReservedCenter ? 1 : 0);
}


/**
 * Returns a `centerType` that is internally consistent with `size`.
 *
 * Even boards have no center concept; the form hides the center
 * selector for them, so any non-NONE leakage (from prefs, a malformed
 * draft, or a stale reset) would be unfixable from the UI. Coerce to
 * NONE in those cases.
 *
 * Used in three places that all need to converge on the same rule:
 * the initial-state factory, `setSize`, and `reset`.
 */
function coerceCenterType(
  size: 3 | 4 | 5,
  desired: CenterSquareType,
): CenterSquareType {
  const isOdd = size % 2 !== 0;
  if (!isOdd) return CenterSquareType.NONE;
  // Odd boards: NONE is allowed but we usually want a visible default
  // when prefs don't pick one. Honor whatever the caller asked for.
  return desired;
}

/** All wizard state held by the controller. */
export interface BoardWizardState {
  // Step 1 fields
  name: string;
  size: 3 | 4 | 5;
  timeframe: Timeframe;
  customStartDate: string; // YYYY-MM-DD
  customEndDate: string; // YYYY-MM-DD
  centerType: CenterSquareType;
  isRandomized: boolean;
  weekStartDay: WeekStartDay;

  // Board Creation Split (web PR C) — whether this wizard instance is
  // the recurring (BLUE) flow or the one-off (RED) flow. **Fixed at
  // entry, for the lifetime of this controller** — there is no
  // mid-wizard "Repeats" control anymore (the old Step-1 segmented +
  // `setRepeats` toggle machinery retired). The two Create-hub CTAs
  // launch separate wizard sessions with mode already decided; editing
  // an existing recurring board always starts recurring
  // (`editingTemplate` hydration). Hides Custom from the timeframe
  // selector (recurring schema rejects it) and CHOSEN from the
  // center-type selector.
  //
  // When true, the wizard saves a `RecurringBoardTemplate` (and
  // immediately spawns the current window's board); when false, it
  // saves a plain Board as before. The pool is always loose-fit
  // (>= cell count); the spawn shuffles + slices, so any extras become
  // the random subset.
  isRecurring: boolean;

  // Step 2 fields
  selectedTaskIds: Set<string>;
  centerTaskId: string | null;

  /**
   * Web inline-editing port PR-1 — insertion order of the pool, kept in
   * sync with `selectedTaskIds` by `syncPoolOrder` after every action that
   * can add/remove members. Mirrors iOS `BoardWizardViewModel.poolOrder`:
   * the Tasks step's pool list renders in THIS order (never alphabetical
   * or re-sorted) so a task keeps its position when a later PR's inline
   * editor renames it in place. No drag-reorder — placement is decided at
   * board generation and reshuffles per spawn, so this only needs to
   * survive add/remove, not user-driven reordering.
   */
  poolOrder: string[];

  /**
   * P3 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
   * §Surfaces item 5 "Wizard step 2") — pool ids the user has pulled into
   * the current selection, in pull order (this order doubles as the exact
   * array persisted as `RecurringBoardTemplate.poolIds`). Empty for a
   * fresh wizard / one-off board / any session where the user never opens
   * the "PULL IN A POOL" card.
   */
  pulledPoolIds: string[];
  /**
   * P3 — task ids explicitly hand-added (not pool-sourced). Hydrated from
   * `RecurringBoardTemplate.manualTaskIds` when editing an existing
   * template; for a fresh wizard / draft resume it starts as the initial
   * `selectedTaskIds` (draft boardTasks, or a legacy DefaultPool prefill —
   * see `useBoardWizard`'s hydration comments) since there's no pool-mix
   * provenance to recover for those sources.
   */
  manualTaskIds: Set<string>;
  /**
   * P3 — task ids explicitly removed from the selection while still
   * pool-supplied (bookkeeping only — never rendered directly). Hydrated
   * from `RecurringBoardTemplate.removedTaskIds` when editing an existing
   * template; starts empty otherwise. See `@oybc/shared`'s `poolMix`
   * module docstring for the full removals semantics.
   */
  removedTaskIds: Set<string>;

  /**
   * Bug #85 — In-memory pending tasks created inside the wizard.
   *
   * Keyed by task id. These have NOT been written to the DB yet.
   * `persistWizardBoard` writes them inside the board-save transaction
   * before writing board_tasks, so the window between "task exists"
   * and "board references it" is zero. Abandoning the wizard simply
   * discards this map — nothing needs to be cleaned up.
   *
   * Compounds store the parent task under its own id; `childTasks` and
   * `childLinks` hold the inline-created children and link rows.
   */
  pendingTasks: Map<string, PendingTaskPayload>;

  /**
   * Inline Task Editing (web PR-2) — staged, not-yet-persisted inline edits
   * to pooled tasks. Keyed by taskId. Mirrors iOS
   * `BoardWizardViewModel.stagedEdits`: applied ONLY inside the board-create
   * transaction (`persistWizardBoardRows` / the recurring-template persist
   * path) — never while the board is a draft. A task leaving the pool
   * (deselect, or a pool untoggle that drops it) always purges its entry
   * here — see `toggleTaskSelection` / `untogglePool`.
   */
  stagedEdits: Map<string, TaskEditPatch>;

  // Wizard navigation
  currentStep: WizardStep;

  /** Set when the wizard was hydrated from an existing draft board.
   *  Non-null means Save / Activate will update this record rather
   *  than create a new one. Mutually exclusive with `editingTemplateId`. */
  draftBoardId: string | null;

  /** Set when the wizard was hydrated from an existing recurring
   *  template (Profile → Recurring templates → Edit). Save updates the
   *  template (and does NOT retroactively edit previously-spawned
   *  boards or trigger a fresh spawn). Mutually exclusive with
   *  `draftBoardId`. */
  editingTemplateId: string | null;

  /** Phase 6.1 — true iff the wizard was launched from the recurring
   *  banner (`prefilledRecurringTimeframe != undefined`). Persisted on
   *  the created Board as `isCore: true`, which is the marker the
   *  `findPendingRecurringBoards` detector checks when deciding whether
   *  to keep showing the banner. Manual Create-page opens (no prefill)
   *  leave this false → resulting Board is non-core → banner persists. */
  isCore: boolean;

  /** Phase B — when the wizard was launched from the core-board browser
   *  to spawn a non-current window, this is the reference date for the
   *  target window. Threaded to `resolveWizardDates(controller, this)`
   *  by the persist path so the board's `startDate`/`endDate` match the
   *  picked window. Null when the user is creating today's window
   *  (banner click) or any non-recurring board — `resolveWizardDates`
   *  falls back to `new Date()` in that case. */
  targetWindowDate: Date | null;
}

/** Mutators for each piece of state. */
export interface BoardWizardActions {
  setName: (v: string) => void;
  setSize: (s: 3 | 4 | 5) => void;
  setTimeframe: (t: Timeframe) => void;
  setCustomStartDate: (d: string) => void;
  setCustomEndDate: (d: string) => void;
  setCenterType: (t: CenterSquareType) => void;
  toggleTaskSelection: (taskId: string) => void;
  setCenterTaskId: (id: string | null) => void;
  /**
   * P3 — "PULL IN A POOL" toggle ON. Unions the pool's resolvable,
   * not-currently-removed supply into `selectedTaskIds` and appends the
   * pool id to `pulledPoolIds`. No-ops for a missing/soft-deleted/
   * already-pulled pool.
   */
  pullPool: (poolId: string) => void;
  /**
   * P3 — "PULL IN A POOL" toggle OFF. Removes only the pool's non-manual
   * tasks not also supplied by a remaining pulled pool; the manual layer
   * and the saved Pool itself are never touched.
   */
  untogglePool: (poolId: string) => void;
  goToStep: (step: WizardStep) => void;
  goNext: () => void;
  goBack: () => void;
  reset: () => void;
  /**
   * Bug #85 — Store a newly-created pending task payload in the wizard's
   * in-memory map. Called by the Tasks step's `onPendingCreated` callback
   * immediately after `toggleTaskSelection` adds the task id to
   * `selectedTaskIds`. Deselecting the task via `toggleTaskSelection`
   * automatically removes its pending payload.
   */
  addPendingTask: (payload: PendingTaskPayload) => void;
  /**
   * Inline Task Editing (web PR-2) — stage an inline edit for `taskId`
   * (no DB write). Returns the PREVIOUS patch (or `undefined` if this is
   * the first edit for this task) so the caller's Save toast can offer an
   * Undo that reverts to it via `revertEdit`. Mirrors iOS
   * `BoardWizardViewModel.stageEdit`.
   */
  stageEdit: (taskId: string, patch: TaskEditPatch) => TaskEditPatch | undefined;
  /**
   * Inline Task Editing (web PR-2) — undo a staged edit: restores
   * `previous` (or removes the entry entirely when `previous` is
   * `undefined` — i.e. this task had no prior staged edit). Mirrors iOS
   * `BoardWizardViewModel.revertEdit`.
   */
  revertEdit: (taskId: string, previous: TaskEditPatch | undefined) => void;
  /**
   * Inline Task Editing (web PR-2) — restore a removed task to the pool at
   * its original index (re-adding its pending payload when non-`null`).
   * Backs the Remove ✕ toast's Undo. Mirrors iOS
   * `BoardWizardViewModel.restoreToPool`.
   */
  restoreToPool: (taskId: string, index: number, payload: PendingTaskPayload | undefined) => void;
}

/** Computed flags exposed to step components for validation + display. */
export interface BoardWizardDerived {
  /** Number of pool tasks the chosen geometry requires. */
  tasksRequired: number;
  /** True when CHOSEN center type is selected (drives the star radio). */
  centerMode: boolean;
  /** True when Step 1 is complete enough to advance. */
  isStep1Valid: boolean;
  /** True when Step 2 has enough selections + a center if required. */
  isStep2Valid: boolean;
  /** Optional inline validation message for Step 1. */
  step1ValidationMessage: string | null;
  /** Optional inline validation message for Step 2. */
  step2ValidationMessage: string | null;
  /** True when no meaningful edit has been made — the wizard can be
   *  dismissed without prompting. When a draft is being resumed this
   *  is always `false`: closing a resumed draft is always a decision
   *  worth confirming. */
  isPristine: boolean;
  /**
   * P3 — provenance label ("from Morning Kickstart" / "added by hand")
   * for every currently-selected task id, for the Tasks step's row
   * subtitles. Only ids in `selectedTaskIds` are populated. See
   * `deriveTaskProvenance` for the resolution rule.
   */
  taskProvenance: Map<string, string>;
}

export type BoardWizardController = BoardWizardState &
  BoardWizardActions &
  BoardWizardDerived;

/** Payload supplied when resuming an existing draft board. The wizard
 *  hydrates every field from the Board record and rebuilds
 *  `selectedTaskIds` from the BoardTask rows. */
export interface BoardWizardDraft {
  board: Board;
  boardTasks: BoardTask[];
}

export interface UseBoardWizardArgs {
  /** Synced user preferences — used to seed defaults when no draft
   *  is supplied, or as a fallback for fields missing on a draft. */
  preferences: UserPreferences;
  /** Authenticated user id. Used by the P5 core-board-default prefill
   *  path: when the wizard is launched from the recurring banner / core-
   *  board browser and a `CoreBoardDefault` exists for
   *  `(userId, timeframe)`, `selectedTaskIds`/`pulledPoolIds` are hydrated
   *  from its `corePoolIds` + `coreDefaultTaskIds`. Optional so the
   *  wizard still compiles for tests / playgrounds that don't have an
   *  auth context. */
  userId?: string;
  /** Optional starting step (defaults to 1). Useful for tests / drafts. */
  initialStep?: WizardStep;
  /** If provided, the wizard hydrates every field from this draft and
   *  subsequent Save / Activate actions update this record rather than
   *  creating a new one. */
  draft?: BoardWizardDraft;
  /** When set, the wizard is opened from the Boards-tab Recurring
   *  Boards banner. The timeframe is seeded from this value (overriding
   *  `preferences.defaultTimeframe`) and a sensible default name is
   *  precomputed via `formatTimeframeLabel`. The setup step locks the
   *  timeframe field so the user can't accidentally pick a different
   *  one — they can edit name/size/center as usual.
   *
   *  Banner deep-links also turn ON `isRecurring` (since the user is
   *  explicitly creating a recurring instance) so the persist path
   *  saves a template + spawns the current window.
   *
   *  Mutually exclusive with `draft` and `editingTemplate` (drafts and
   *  template-edits already lock semantics by hydrating the full
   *  record). When more than one is supplied, the priority is:
   *  draft > editingTemplate > prefilledRecurringTimeframe. */
  prefilledRecurringTimeframe?: Timeframe;
  /** Optional target-window reference date for the prefill. When
   *  provided alongside `prefilledRecurringTimeframe`, the wizard
   *  resolves boundaries with this date instead of `new Date()` — i.e.
   *  the user can pre-spawn a future window from the core-board
   *  browser. The default (undefined) reproduces the original "today's
   *  window" behaviour of the recurring banner. Ignored when there's
   *  no prefilled timeframe (drafts and one-off boards don't need it).
   *
   *  Threaded through to `resolveWizardDates` so the persisted
   *  `startDate`/`endDate` reflect the target window, not today.
   */
  targetWindowDate?: Date;
  /** When set, the wizard is opened in template-edit mode (Profile →
   *  Recurring templates → Edit). All fields hydrate from the template,
   *  `isRecurring` is forced ON, and Save updates the template via
   *  `updateRecurringBoardTemplate` rather than spawning a fresh
   *  template + board. Mutually exclusive with `draft`. */
  editingTemplate?: RecurringBoardTemplate;
  /**
   * Board Creation Split (web PR C) — the recurring-hub-card entry
   * point: a fresh wizard with no draft/template/prefill starts in
   * recurring mode when true. Ignored (mode is derived from the
   * hydration source instead) whenever `draft`, `editingTemplate`, or
   * `prefilledRecurringTimeframe` is supplied. Defaults to `false` so
   * every existing one-off call site is unaffected. Mirrors iOS
   * `BoardWizardViewModel.init`'s `startRecurring` parameter.
   */
  startRecurring?: boolean;
  /**
   * P3 (Task Pools + Recurring Boards Rework) — the user's non-deleted
   * pools, used to resolve `pullPool`/`untogglePool` and the provenance
   * derivation. Callers should load this ONCE via `usePools(userId)` and
   * pass it here — `BoardWizardPage` also threads the same array to
   * `BoardWizardTasksStep`'s "PULL IN A POOL" card so the wizard doesn't
   * run two concurrent `usePools` live queries (mirrors the
   * `PoolsBrowse`/`TasksPage` "load once, pass down" precedent). Defaults
   * to `[]` when omitted — pool actions become no-ops, which is a safe
   * fallback for callers (tests, future playgrounds) that don't have a
   * pools source.
   */
  pools?: Pool[];
  /**
   * P3 — id→Task lookup used to resolve pool-pull/untoggle additions/
   * removals and provenance labels. Callers should pass
   * `useTaskLibrary(userId).taskMap` (already loaded at `BoardWizardPage`
   * for the Tasks step — reusing it here avoids a duplicate live task
   * query). Defaults to `{}` when omitted (pool actions degrade to "no
   * resolvable tasks" — harmless, since the affected UI always has the
   * library loaded in production).
   */
  tasksById?: Record<string, Task>;
}

/**
 * useBoardWizard — Owns the full board-creation wizard state.
 *
 * Initializes from `UserPreferences` on mount; any later preference change
 * does NOT stomp in-progress wizard state (the wizard takes a snapshot
 * of defaults at construction). All step components are fully
 * controlled — they read from this controller's state and call the
 * exposed setters / nav actions.
 *
 * Validation is exposed as derived booleans (`isStep1Valid`, `isStep2Valid`)
 * so each step can disable its own Next button without re-implementing the
 * count-needed math.
 */
export function useBoardWizard({
  preferences,
  userId,
  initialStep = 1,
  draft,
  prefilledRecurringTimeframe,
  targetWindowDate,
  editingTemplate,
  startRecurring = false,
  pools = EMPTY_POOLS,
  tasksById = EMPTY_TASKS_BY_ID,
}: UseBoardWizardArgs): BoardWizardController {
  const draftBoard = draft?.board;

  // P3 — id→Pool lookup for pull/untoggle/provenance. Rebuilt only when
  // the `pools` array identity changes (the caller's live query).
  const poolsById = useMemo<Record<string, Pool>>(() => {
    const map: Record<string, Pool> = {};
    for (const p of pools) map[p.id] = p;
    return map;
  }, [pools]);

  // Hydration priority: draft > editingTemplate > prefilledRecurringTimeframe
  // > startRecurring. When a draft is being resumed we ignore the other
  // three — drafts already hydrate the full record, so honoring extra
  // prefills on top would confuse the user about which board they're
  // editing. Editing a template wins over a banner-deep-link prefill since
  // the template is a more-specific source; a bare `startRecurring` flag
  // (recurring hub-card tap) is the weakest signal — it only matters for a
  // truly fresh wizard.
  const effectiveTemplate = !draftBoard ? editingTemplate ?? undefined : undefined;
  const effectivePrefill =
    !draftBoard &&
    !effectiveTemplate &&
    prefilledRecurringTimeframe !== undefined &&
    prefilledRecurringTimeframe !== Timeframe.CUSTOM
      ? prefilledRecurringTimeframe
      : null;

  // Board Creation Split (web PR C) — mode is now decided ONCE, from the
  // hydration source or the launch-time `startRecurring` flag, and never
  // changes for the lifetime of this controller (no more Step-1 "Repeats"
  // segmented / `setRepeats` toggle). A wizard *starts* recurring when
  // editing an existing template, OR when launched fresh from the
  // recurring hub card (`startRecurring`). A `prefilledRecurringTimeframe`
  // (banner / core-board browser) creates a one-off *core* board for that
  // window — NOT a repeating board — so it does not flip `isRecurring`
  // (#70) and takes priority over `startRecurring` (mutually exclusive in
  // practice: callers never pass both).
  const isFreshRecurringFromHub =
    draftBoard === undefined &&
    effectiveTemplate === undefined &&
    effectivePrefill === null &&
    startRecurring === true;
  const initialIsRecurring = effectiveTemplate !== undefined || isFreshRecurringFromHub;

  const [name, setName] = useState(() => {
    if (draftBoard) return draftBoard.name;
    if (effectiveTemplate) return effectiveTemplate.name;
    if (effectivePrefill !== null) {
      // Seed with a human-readable label like "Today" / "Week of May 4 – 10,
      // 2026" / "May 2026" / "2026". User can edit before saving.
      // `targetWindowDate` (when present) selects a non-today window so
      // the seed name matches the window the user is actually creating.
      const { startDate } = getTimeframeBoundaries(
        effectivePrefill,
        targetWindowDate ?? new Date(),
        preferences.weekStartDay,
      );
      return formatTimeframeLabel(effectivePrefill, startDate);
    }
    return '';
  });
  const [size, setSizeRaw] = useState<3 | 4 | 5>(
    () =>
      (draftBoard?.boardSize as 3 | 4 | 5 | undefined) ??
      (effectiveTemplate?.boardSize as 3 | 4 | 5 | undefined) ??
      preferences.defaultBoardSize,
  );
  // Live mirror of `size` so `setSize` can read the previous value
  // synchronously (matching iOS `updateSize`, which reads the model
  // property) — a render-closure read would go stale if `setSize` were
  // called twice in one render. Synced via effect so external size changes
  // (e.g. `reset`) keep it current.
  const sizeRef = useRef(size);
  useEffect(() => {
    sizeRef.current = size;
  }, [size]);
  const [timeframe, setTimeframeRaw] = useState<Timeframe>(() => {
    const explicitSource =
      draftBoard?.timeframe ??
      effectiveTemplate?.timeframe ??
      effectivePrefill ??
      null;
    return resolveInitialWizardTimeframe(
      explicitSource,
      preferences.defaultTimeframe,
      initialIsRecurring,
      isFreshRecurringFromHub,
    );
  });
  const [customStartDate, setCustomStartDate] = useState(() =>
    draftBoard?.timeframe === Timeframe.CUSTOM && draftBoard.startDate
      ? draftBoard.startDate.slice(0, 10)
      : '',
  );
  const [customEndDate, setCustomEndDate] = useState(() =>
    draftBoard?.timeframe === Timeframe.CUSTOM && draftBoard.endDate
      ? draftBoard.endDate.slice(0, 10)
      : '',
  );
  const [centerType, setCenterTypeRaw] = useState<CenterSquareType>(() =>
    // Even-size boards have no center concept — the BoardSetupForm
    // hides the center selector for them, so the user can't correct a
    // FREE that leaks in from prefs or a malformed draft.
    // Coerce to NONE here so the initial state is internally consistent
    // (matches the same guard in setSize).
    coerceCenterType(
      (draftBoard?.boardSize as 3 | 4 | 5 | undefined) ??
        (effectiveTemplate?.boardSize as 3 | 4 | 5 | undefined) ??
        preferences.defaultBoardSize,
      draftBoard?.centerSquareType ??
        effectiveTemplate?.centerSquareType ??
        preferences.defaultCenterType,
    ),
  );
  // Issue #69 — board placement is always randomized. There's no
  // manual-placement UI, so the per-board "Randomize positions" toggle
  // (and the `defaultRandomize` preference) were dead UX and have been
  // removed. The `isRandomized` field is retained on
  // Board/RecurringBoardTemplate for schema stability and always
  // written `true`; `buildWizardPlacement` / template spawn shuffle
  // unconditionally.
  const isRandomized = true;
  // Board Creation Split (web PR C) — fixed for the lifetime of this
  // controller (recomputed identically every render from stable inputs,
  // so a plain const is equivalent to "set once at init" without needing
  // its own setState). Mirrors iOS's `let isRecurring`.
  const isRecurring = initialIsRecurring;
  const weekStartDay = preferences.weekStartDay;

  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(() => {
    if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
    // Synchronous fallback only — `effectiveTemplate.seedTaskIds` is stale
    // once P1's legacy-editor write-through has run (it writes through to
    // the linked Pool, not this field; see `useTemplateMix`'s docstring).
    // The one-shot effect below replaces this with the resolved mix as
    // soon as it loads.
    if (effectiveTemplate) return new Set(effectiveTemplate.seedTaskIds);
    return new Set();
  });
  // Web inline-editing port PR-1 — pool insertion order. Derived from
  // `selectedTaskIds`'s OWN initializer (not re-reading `draft`/
  // `effectiveTemplate` separately) so the two can never disagree on
  // first paint or silently duplicate an id. Every subsequent mutation
  // goes through `syncPoolOrder`.
  const [poolOrder, setPoolOrder] = useState<string[]>(() => Array.from(selectedTaskIds));

  // P1 (Task Pools + Recurring Boards Rework) — resolve the template's
  // CURRENT pool-mix task ids and replace the seedTaskIds-based initial
  // state above once loaded. One-shot via a ref flag, same pattern as the
  // DefaultPool prefill effect below: without it, re-opening "Edit"/"Add
  // tasks" a second time would silently drop whatever a prior edit wrote
  // through to the Pool, and Save would destructively overwrite the Pool
  // with the stale set.
  const templateMix = useTemplateMix(effectiveTemplate);
  const templateMixAppliedRef = useRef(false);
  useEffect(() => {
    if (templateMixAppliedRef.current) return;
    if (!effectiveTemplate) return;
    if (templateMix === undefined) return; // still loading
    templateMixAppliedRef.current = true;
    setSelectedTaskIds(templateMix);
    setPoolOrder((prev) => syncPoolOrder(prev, templateMix));
  }, [effectiveTemplate, templateMix]);

  /**
   * P3 (Task Pools + Recurring Boards Rework) — "PULL IN A POOL" state.
   *
   * Editing an existing recurring template hydrates directly from the
   * template's own fields (already resolved, synchronous — unlike
   * `selectedTaskIds`'s `useTemplateMix` resolution above, these three
   * fields need no pool/task lookup to read). A fresh wizard / draft
   * resume (one-off board) carries no persisted pool-mix fields, so
   * `pulledPoolIds`/`removedTaskIds` start empty and `manualTaskIds`
   * starts as the initial `selectedTaskIds` (draft boardTasks, or — via
   * the DefaultPool-prefill effect below — a legacy DefaultPool prefill):
   * every row defaults to "added by hand" until the user touches the new
   * pull-card. This is an explicit, flagged judgment call (P3 spec) —
   * one-off boards have no better provenance to recover. Declared ahead
   * of the prefill effect below since that effect's `setManualTaskIds`
   * needs it in scope.
   */
  const [pulledPoolIds, setPulledPoolIds] = useState<string[]>(
    () => effectiveTemplate?.poolIds ?? [],
  );
  const [manualTaskIds, setManualTaskIds] = useState<Set<string>>(() => {
    if (effectiveTemplate) return new Set(effectiveTemplate.manualTaskIds ?? []);
    if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
    return new Set();
  });
  const [removedTaskIds, setRemovedTaskIds] = useState<Set<string>>(
    () => new Set(effectiveTemplate?.removedTaskIds ?? []),
  );

  // P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
  // §Surfaces item 6 "Core-board setup") — CoreBoardDefault prefill.
  // Replaces the legacy DefaultPool prefill. When the wizard is
  // banner-launched (`effectivePrefill` set) AND no draft/template
  // hydrated the selection, look up the user's CoreBoardDefault for that
  // timeframe and fold its `corePoolIds` + `coreDefaultTaskIds` into
  // `selectedTaskIds`/`pulledPoolIds` via `applyCoreBoardDefaultPrefill`.
  // One-shot via the SAME ref flag `pullPool`/`untogglePool`/
  // `toggleTaskSelection` already set — a user who starts interacting
  // with pool chips before this resolves is respected; a CoreBoardDefault
  // that arrives later via sync can never stomp their edits.
  //
  // `useCoreBoardDefault` returns a tri-state: `undefined` while loading,
  // `null` when there is no default for this timeframe, a
  // `CoreBoardDefault` when one exists. Both `null` and a resolved row
  // are load-complete signals that resolve the one-shot decision; only
  // `undefined` should keep the effect waiting.
  //
  // Deliberately does NOT touch `manualTaskIds` — every prefilled id here
  // is pool- or default-sourced, never hand-added. This is the actual
  // bug fix vs. the legacy DefaultPool effect, which stuffed the entire
  // prefill into `manualTaskIds` (making every prefilled task read as
  // "added by hand" in the Tasks-step provenance subtitles).
  const coreBoardDefault = useCoreBoardDefault(userId, effectivePrefill ?? undefined);
  const poolPrefillAppliedRef = useRef(false);
  useEffect(() => {
    if (poolPrefillAppliedRef.current) return;
    if (draft || effectiveTemplate || effectivePrefill === null) return;
    if (coreBoardDefault === undefined) return; // still loading
    poolPrefillAppliedRef.current = true;
    if (coreBoardDefault === null) return; // no default configured for this timeframe
    const result = applyCoreBoardDefaultPrefill(
      coreBoardDefault.corePoolIds,
      coreBoardDefault.coreDefaultTaskIds,
      poolsById,
      tasksById,
    );
    if (result.selectedTaskIds.size === 0 && result.pulledPoolIds.length === 0) return;
    setSelectedTaskIds(result.selectedTaskIds);
    setPoolOrder((prev) => syncPoolOrder(prev, result.selectedTaskIds));
    setPulledPoolIds(result.pulledPoolIds);
  }, [coreBoardDefault, draft, effectiveTemplate, effectivePrefill, poolsById, tasksById]);
  const [centerTaskId, setCenterTaskIdRaw] = useState<string | null>(
    () => draftBoard?.centerTaskId ?? null,
  );

  /**
   * Bug #85 — In-memory pending tasks. Keyed by task id. These tasks
   * were created inside the wizard's New Task sheet but have NOT been
   * written to the DB. `persistWizardBoard` drains this map inside the
   * board-save transaction. Abandoning the wizard discards the map with
   * zero cleanup because nothing was ever persisted.
   */
  const [pendingTasks, setPendingTasks] = useState<Map<string, PendingTaskPayload>>(
    () => new Map(),
  );

  /**
   * Inline Task Editing (web PR-2) — staged inline task edits. See
   * `BoardWizardState.stagedEdits`'s doc for the full contract.
   */
  const [stagedEdits, setStagedEdits] = useState<Map<string, TaskEditPatch>>(() => new Map());

  const [currentStep, setCurrentStep] = useState<WizardStep>(initialStep);
  const draftBoardId = draftBoard?.id ?? null;
  const editingTemplateId = effectiveTemplate?.id ?? null;

  // Phase 6.1 — banner-launched ⇒ core. Preserve existing draft's
  // core-ness on resume so a banner-launched draft, once resumed and
  // activated, still marks the board as core. Independent of
  // isRecurring (which the user can toggle freely mid-wizard).
  const isCore = draftBoard?.isCore ?? effectivePrefill !== null;

  // ── Coupled setters ───────────────────────────────────────────────────
  // Changing size or center type can invalidate downstream selections;
  // these setters keep the model consistent so step components don't
  // have to re-implement the same guards.

  const setSize = useCallback((s: 3 | 4 | 5) => {
    const oldIsOdd = sizeRef.current % 2 !== 0;
    sizeRef.current = s; // sync so a back-to-back call sees the live value
    setSizeRaw(s);
    const newIsOdd = s % 2 !== 0;
    if (!newIsOdd) {
      setCenterTypeRaw(CenterSquareType.NONE);
      setCenterTaskIdRaw(null);
    } else if (!oldIsOdd) {
      // Only coerce NONE→FREE when actually crossing even→odd (the even
      // board had forced NONE). Re-selecting the same/another odd size
      // must preserve a deliberate NONE the user picked while already odd.
      setCenterTypeRaw((prev) =>
        prev === CenterSquareType.NONE ? CenterSquareType.FREE : prev,
      );
    }
  }, []);

  const setCenterType = useCallback((t: CenterSquareType) => {
    setCenterTypeRaw(t);
    if (t !== CenterSquareType.CHOSEN) {
      setCenterTaskIdRaw(null);
    }
  }, []);

  // Recurring templates exclude `Timeframe.CUSTOM` (no computed window)
  // and `CenterSquareType.CHOSEN` (MVP scope; the schema rejects both).
  // The setup form hides those options when isRecurring=true, but the
  // setter also rejects them defensively so a stale call site or future
  // refactor can't reintroduce an invalid combination.
  const setTimeframe = useCallback(
    (t: Timeframe) => {
      // Recurring boards exclude CUSTOM and INDEFINITE (no computed window /
      // cadence).
      if (isRecurring && (t === Timeframe.CUSTOM || t === Timeframe.INDEFINITE))
        return;
      setTimeframeRaw(t);
    },
    [isRecurring],
  );

  const toggleTaskSelection = useCallback(
    (taskId: string) => {
      // Phase 6.X — user has touched the selection, so any DefaultPool
      // that arrives later via `useLiveQuery` MUST NOT overwrite their
      // edits. Marking the ref here closes the race where the user picks
      // tasks while `defaultPool === undefined` (still loading) and the
      // pool resolution would otherwise re-fire the prefill effect.
      poolPrefillAppliedRef.current = true;
      const wasSelected = selectedTaskIds.has(taskId);
      setSelectedTaskIds((prev) => {
        const next = new Set(prev);
        if (next.has(taskId)) {
          next.delete(taskId);
        } else {
          next.add(taskId);
        }
        return next;
      });
      // Web inline-editing port PR-1 — keep pool order in lockstep. Cheaper
      // than re-deriving from `selectedTaskIds` via `syncPoolOrder` (which
      // would need the freshly-computed Set in scope); a single toggle only
      // ever adds-or-removes exactly `taskId`.
      setPoolOrder((prev) =>
        wasSelected ? prev.filter((id) => id !== taskId) : prev.includes(taskId) ? prev : [...prev, taskId],
      );
      // Clear center mark if the task being deselected was the center.
      setCenterTaskIdRaw((prev) => (prev === taskId ? null : prev));
      // Bug #85 — When the user deselects a pending (not-yet-persisted)
      // task, remove it from the pending map so it won't be written at
      // board-save time. If it was never pending (library task), this is
      // a no-op because `pendingTasks` won't contain its id.
      setPendingTasks((prev) => {
        if (!prev.has(taskId)) return prev;
        const next = new Map(prev);
        next.delete(taskId);
        return next;
      });
      // Inline Task Editing (web PR-2) — a task leaving the pool always
      // purges its staged edit too (mirrors iOS's exact invariant note on
      // `saveWizardBoard`'s `stagedEdits` parameter).
      setStagedEdits((prev) => {
        if (!prev.has(taskId)) return prev;
        const next = new Map(prev);
        next.delete(taskId);
        return next;
      });

      // P3 — manual/removed bookkeeping. `wasSelected` (captured above,
      // pre-toggle) decides which side of the select/deselect we're on.
      if (wasSelected) {
        const result = applyManualBookkeepingOnDeselect(
          taskId,
          manualTaskIds,
          removedTaskIds,
          pulledPoolIds,
          poolsById,
          tasksById,
        );
        setManualTaskIds(result.manualTaskIds);
        setRemovedTaskIds(result.removedTaskIds);
      } else {
        const result = applyManualBookkeepingOnSelect(taskId, manualTaskIds, removedTaskIds);
        setManualTaskIds(result.manualTaskIds);
        setRemovedTaskIds(result.removedTaskIds);
      }
    },
    [selectedTaskIds, manualTaskIds, removedTaskIds, pulledPoolIds, poolsById, tasksById],
  );

  /**
   * P3 — "PULL IN A POOL" toggle ON. See `BoardWizardActions.pullPool`.
   */
  const pullPool = useCallback(
    (poolId: string) => {
      poolPrefillAppliedRef.current = true;
      const result = applyPullPool(
        poolId,
        selectedTaskIds,
        pulledPoolIds,
        removedTaskIds,
        poolsById,
        tasksById,
      );
      setSelectedTaskIds(result.selectedTaskIds);
      setPoolOrder((prev) => syncPoolOrder(prev, result.selectedTaskIds));
      setPulledPoolIds(result.pulledPoolIds);
    },
    [selectedTaskIds, pulledPoolIds, removedTaskIds, poolsById, tasksById],
  );

  /**
   * P3 — "PULL IN A POOL" toggle OFF. See `BoardWizardActions.untogglePool`.
   */
  const untogglePool = useCallback(
    (poolId: string) => {
      poolPrefillAppliedRef.current = true;
      const result = applyUntogglePool(
        poolId,
        selectedTaskIds,
        pulledPoolIds,
        manualTaskIds,
        removedTaskIds,
        poolsById,
        tasksById,
      );
      setSelectedTaskIds(result.selectedTaskIds);
      setPoolOrder((prev) => syncPoolOrder(prev, result.selectedTaskIds));
      setPulledPoolIds(result.pulledPoolIds);
      setRemovedTaskIds(result.removedTaskIds);
      if (result.removedIds.length > 0) {
        const removedSet = new Set(result.removedIds);
        setCenterTaskIdRaw((prev) => (prev !== null && removedSet.has(prev) ? null : prev));
        setPendingTasks((prev) => {
          let changed = false;
          const next = new Map(prev);
          for (const id of result.removedIds) {
            if (next.has(id)) {
              next.delete(id);
              changed = true;
            }
          }
          return changed ? next : prev;
        });
        // Inline Task Editing (web PR-2) — a pool untoggle can drop tasks
        // from the selection too; purge their staged edits the same as a
        // manual deselect does.
        setStagedEdits((prev) => {
          let changed = false;
          const next = new Map(prev);
          for (const id of result.removedIds) {
            if (next.has(id)) {
              next.delete(id);
              changed = true;
            }
          }
          return changed ? next : prev;
        });
      }
    },
    [selectedTaskIds, pulledPoolIds, manualTaskIds, removedTaskIds, poolsById, tasksById],
  );

  /**
   * Bug #85 — Store a pending task payload in the wizard's in-memory
   * map. Called by the Tasks step immediately after the New Task sheet
   * fires `onTaskCreated` (which calls `toggleTaskSelection` to add
   * the id to the selection set). The caller is responsible for calling
   * `toggleTaskSelection` first so the id is always in `selectedTaskIds`
   * before this fires.
   */
  const addPendingTask = useCallback((payload: PendingTaskPayload) => {
    setPendingTasks((prev) => {
      const next = new Map(prev);
      next.set(payload.task.id, payload);
      return next;
    });
  }, []);

  /**
   * Inline Task Editing (web PR-2) — stage an inline edit. See
   * `BoardWizardActions.stageEdit`.
   */
  const stageEdit = useCallback((taskId: string, patch: TaskEditPatch): TaskEditPatch | undefined => {
    let previous: TaskEditPatch | undefined;
    setStagedEdits((prev) => {
      previous = prev.get(taskId);
      const next = new Map(prev);
      next.set(taskId, patch);
      return next;
    });
    return previous;
  }, []);

  /**
   * Inline Task Editing (web PR-2) — undo a staged edit. See
   * `BoardWizardActions.revertEdit`.
   */
  const revertEdit = useCallback((taskId: string, previous: TaskEditPatch | undefined) => {
    setStagedEdits((prev) => {
      const next = new Map(prev);
      if (previous === undefined) {
        next.delete(taskId);
      } else {
        next.set(taskId, previous);
      }
      return next;
    });
  }, []);

  /**
   * Inline Task Editing (web PR-2) — restore a removed task to the pool at
   * its original index. See `BoardWizardActions.restoreToPool`.
   *
   * Deliberately does NOT route through `toggleTaskSelection` (which always
   * appends at the end of `poolOrder`) — Undo must restore the task at the
   * exact index it was removed from, mirroring iOS
   * `BoardWizardViewModel.restoreToPool`.
   */
  const restoreToPool = useCallback(
    (taskId: string, index: number, payload: PendingTaskPayload | undefined) => {
      setSelectedTaskIds((prev) => {
        if (prev.has(taskId)) return prev;
        const next = new Set(prev);
        next.add(taskId);
        return next;
      });
      setPoolOrder((prev) => {
        if (prev.includes(taskId)) return prev;
        const next = [...prev];
        next.splice(Math.min(Math.max(index, 0), next.length), 0, taskId);
        return next;
      });
      if (payload !== undefined) {
        setPendingTasks((prev) => {
          const next = new Map(prev);
          next.set(taskId, payload);
          return next;
        });
      }
      // A restored task was hand-removed (its own manual-bookkeeping state
      // is otherwise unrecoverable here) — treat it as manually re-added,
      // matching `applyManualBookkeepingOnSelect`'s "select" branch.
      const result = applyManualBookkeepingOnSelect(taskId, manualTaskIds, removedTaskIds);
      setManualTaskIds(result.manualTaskIds);
      setRemovedTaskIds(result.removedTaskIds);
    },
    [manualTaskIds, removedTaskIds],
  );

  const setCenterTaskId = useCallback((id: string | null) => {
    setCenterTaskIdRaw(id);
  }, []);

  // ── Step navigation ───────────────────────────────────────────────────

  const goToStep = useCallback((step: WizardStep) => {
    setCurrentStep(step);
  }, []);

  const goNext = useCallback(() => {
    setCurrentStep((s) => (s < 3 ? ((s + 1) as WizardStep) : s));
  }, []);

  const goBack = useCallback(() => {
    setCurrentStep((s) => (s > 1 ? ((s - 1) as WizardStep) : s));
  }, []);

  const reset = useCallback(() => {
    setName('');
    // Re-apply size + centerType through the same coercion the initial
    // factory uses, so reset can never reintroduce an even-board+FREE
    // mismatch. Going via `setSizeRaw` + `coerceCenterType` rather than
    // calling `setSize` so the centerType honours the pref instead of
    // always being normalised to FREE.
    const nextSize = preferences.defaultBoardSize;
    setSizeRaw(nextSize);
    setCenterTypeRaw(coerceCenterType(nextSize, preferences.defaultCenterType));
    // Board Creation Split (web PR C) — `isRecurring` is fixed for this
    // controller's lifetime, so reset() must respect the current mode
    // rather than resolving the one-off `defaultTimeframe` preference
    // unconditionally. Mirrors init's own per-mode default.
    if (isRecurring) {
      setTimeframeRaw(Timeframe.WEEKLY);
    } else {
      // Mirror the init seed's CUSTOM→INDEFINITE default so a reset wizard
      // opens ongoing (End date = None), not on CUSTOM with empty dates.
      setTimeframeRaw(
        preferences.defaultTimeframe === Timeframe.CUSTOM
          ? Timeframe.INDEFINITE
          : preferences.defaultTimeframe,
      );
    }
    setCustomStartDate('');
    setCustomEndDate('');
    setSelectedTaskIds(new Set());
    setPoolOrder([]);
    setCenterTaskIdRaw(null);
    setPendingTasks(new Map());
    setStagedEdits(new Map());
    setCurrentStep(1);
    // P3 — reset the pool-mix bookkeeping alongside the selection it describes.
    setPulledPoolIds([]);
    setManualTaskIds(new Set());
    setRemovedTaskIds(new Set());
  }, [preferences, isRecurring]);

  // ── Derived flags ─────────────────────────────────────────────────────

  const tasksRequired = useMemo(
    () => tasksNeededFor(size, centerType),
    [size, centerType],
  );
  const centerMode = centerType === CenterSquareType.CHOSEN;

  const trimmedName = name.trim();
  const isStep1Valid = useMemo(() => {
    if (trimmedName.length === 0) return false;
    if (timeframe === Timeframe.CUSTOM) {
      if (!customStartDate || !customEndDate) return false;
      if (customEndDate < customStartDate) return false;
    }
    return true;
  }, [trimmedName, timeframe, customStartDate, customEndDate]);

  const step1ValidationMessage = useMemo<string | null>(() => {
    if (trimmedName.length === 0) return 'Board name is required.';
    if (timeframe === Timeframe.CUSTOM) {
      if (!customStartDate || !customEndDate) return 'Pick a start and end date.';
      if (customEndDate < customStartDate) {
        return 'End date must be on or after the start date.';
      }
    }
    return null;
  }, [trimmedName, timeframe, customStartDate, customEndDate]);

  // Pool-size enforcement is loose-fit on both branches:
  //   - One-off (isRecurring=false): `selectedCount >= tasksRequired`.
  //     Extras are silently dropped by `buildWizardPlacement`.
  //   - Recurring (isRecurring=true): `selectedCount >= tasksRequired`.
  //     The spawn shuffles + slices, so extras become the random subset.
  // The earlier strict-fit "Use every task" branch was dropped during
  // the Phase 6.2 UX rework — it was a special case of loose-fit where
  // the user picked exactly N.
  const isStep2Valid = useMemo(() => {
    if (selectedTaskIds.size < tasksRequired) return false;
    if (centerMode) {
      if (centerTaskId === null) return false;
      if (!selectedTaskIds.has(centerTaskId)) return false;
    }
    return true;
  }, [selectedTaskIds, tasksRequired, centerMode, centerTaskId]);

  const step2ValidationMessage = useMemo<string | null>(() => {
    const short = tasksRequired - selectedTaskIds.size;
    if (short > 0) {
      const noun = `task${short === 1 ? '' : 's'}`;
      if (isRecurring) return `Pick ${short} more ${noun} (${tasksRequired} minimum).`;
      return `Pick ${short} more ${noun}.`;
    }
    if (centerMode && (centerTaskId === null || !selectedTaskIds.has(centerTaskId))) {
      return 'Mark one selected task as the center.';
    }
    return null;
  }, [selectedTaskIds, tasksRequired, centerMode, centerTaskId, isRecurring]);

  const isPristine = useMemo<boolean>(() => {
    if (draftBoardId !== null) return false;
    if (trimmedName.length > 0) return false;
    if (selectedTaskIds.size > 0) return false;
    if (currentStep > 1) return false;
    return true;
  }, [draftBoardId, trimmedName, selectedTaskIds, currentStep]);

  // P3 — provenance label per currently-selected task id, for the Tasks
  // step's row subtitles.
  const taskProvenance = useMemo(
    () => deriveTaskProvenance(selectedTaskIds, manualTaskIds, pulledPoolIds, poolsById, tasksById),
    [selectedTaskIds, manualTaskIds, pulledPoolIds, poolsById, tasksById],
  );

  return {
    // State
    name,
    size,
    timeframe,
    customStartDate,
    customEndDate,
    centerType,
    isRandomized,
    isRecurring,
    weekStartDay,
    selectedTaskIds,
    centerTaskId,
    poolOrder,
    pulledPoolIds,
    manualTaskIds,
    removedTaskIds,
    pendingTasks,
    stagedEdits,
    currentStep,
    draftBoardId,
    editingTemplateId,
    isCore,
    targetWindowDate: targetWindowDate ?? null,

    // Actions
    setName,
    setSize,
    setTimeframe,
    setCustomStartDate,
    setCustomEndDate,
    setCenterType,
    toggleTaskSelection,
    setCenterTaskId,
    pullPool,
    untogglePool,
    addPendingTask,
    stageEdit,
    revertEdit,
    restoreToPool,
    goToStep,
    goNext,
    goBack,
    reset,

    // Derived
    tasksRequired,
    centerMode,
    isStep1Valid,
    isStep2Valid,
    step1ValidationMessage,
    step2ValidationMessage,
    isPristine,
    taskProvenance,
  };
}
