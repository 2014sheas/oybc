/**
 * boardWizardTypes.ts — the wizard controller's type surface, extracted
 * from `useBoardWizard.ts` (Board Sources P4; ROADMAP B6 posture — the
 * hook file was over its frozen size cap and the ~350 doc-commented
 * interface lines are a clean seam). Pure types, no runtime code.
 * `useBoardWizard.ts` re-exports everything here, so existing import
 * sites are unaffected.
 */

import type {
  BoardSource,
  Board,
  BoardTask,
  CenterSquareType,
  Pool,
  RecurringBoardTemplate,
  Task,
  Timeframe,
  UserPreferences,
  WeekStartDay,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import type { SupplyInfoMap } from './wizardSources';

/** A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate. */
export type WizardStep = 1 | 2 | 3;

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
   * sync with `selectedTaskIds` by every action that
   * can add/remove members. Mirrors iOS `BoardWizardViewModel.poolOrder`:
   * the Tasks step's pool list renders in THIS order (never alphabetical
   * or re-sorted) so a task keeps its position when a later PR's inline
   * editor renames it in place. No drag-reorder — placement is decided at
   * board generation and reshuffles per spawn, so this only needs to
   * survive add/remove, not user-driven reordering.
   */
  poolOrder: string[];

  /**
   * Board Sources P4 (docs/BOARD_SOURCES.md) — the pulled sources, one
   * per "On your board" row, in row order. THE step-2 model; persisted
   * natively as `sources` on the template / draft blob. Each carries its
   * own range, excludes, and (boards) done-filter.
   */
  sources: BoardSource[];
  /**
   * Board Sources P4 — task ids explicitly hand-added (not
   * source-supplied). Hydrated from `manualTaskIds` when editing a
   * template / resuming a draft blob; for a legacy blob-less one-off
   * draft it starts as the placed rows (all hand-added — no better
   * provenance to recover).
   */
  manualTaskIds: Set<string>;
  /**
   * Board Sources P4 — per-source display + raw-supply cache: pool
   * entries resolve live from props; board entries via async fetch. Step
   * components read this for row titles, member lists, and counts.
   */
  supplyInfoBySourceId: SupplyInfoMap;
  /** Board Sources P4 — expanded source rows (UI-only, never persisted). */
  expandedSourceIds: Set<string>;
  /**
   * LEGACY mirror (P1 dual-write) — pool-kind source ids in row order.
   * Derived from `sources`; persisted alongside them for old-client
   * compat. Never mutate directly.
   */
  pulledPoolIds: string[];
  /**
   * LEGACY mirror (P1 dual-write) — the flat union of every source's
   * `excludedTaskIds`. Derived from `sources`. Never mutate directly.
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
   * Board Sources P4 — pull a pool as a source row (default `[0, all]`
   * range). No-op when already pulled; the sheet's un-toggle is
   * `removeSource`.
   */
  pullPool: (poolId: string) => void;
  /** Board Sources P4 — pull a board as a source row (filter "all"). */
  pullBoard: (boardId: string) => void;
  /**
   * Board Sources P4 — remove a source row. Ids only that row supplied
   * leave the selection (center/pending/staged purge with them); the
   * saved Pool/Board is untouched.
   */
  removeSource: (sourceId: string) => void;
  /** Board Sources P4 — set a source's range (`max: null` = "all"). */
  setSourceRange: (sourceId: string, min: number, max: number | null) => void;
  /** Board Sources P4 — "Use all": reset a source's range to `[0, all]`. */
  resetSourceRange: (sourceId: string) => void;
  /** Board Sources P4 — flip a board source's done-filter. */
  setSourceFilter: (sourceId: string, filter: 'all' | 'todo') => void;
  /** Board Sources P4 — toggle one member's exclusion inside one source. */
  toggleSourceExclude: (sourceId: string, taskId: string) => void;
  /** Board Sources P4 — expand/collapse a source row. */
  toggleExpandedSource: (sourceId: string) => void;
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
   * Board Sources P4 — the header/gate CAPACITY: sum of every source's
   * effective max + hand-added, deduped by task (docs/BOARD_SOURCES.md
   * §Selection step 3). Replaces `selectedTaskIds.size` everywhere the
   * step counts or gates.
   */
  capacity: number;
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

