import { AchievementTrigger, OperatorType, TaskType, Timeframe } from '../constants/enums';

/**
 * Task - Reusable task definition
 *
 * Design principles:
 * - Tasks are reusable across multiple boards
 * - LIFETIME-CACHE completion state lives on Task (`isCompleted`,
 *   `currentCount`, `completedAt`) — Windowed Completion
 *   (docs/WINDOWED_COMPLETION.md §Task caches) demoted these to caches over
 *   the `task_events` log: read them ONLY on library/global surfaces and for
 *   the derived shared-counter carve-out. A board renders each task against
 *   ITS window (`resolveTaskWindowState` / `computeBoardGrid`) — reading
 *   these fields for anything windowed is the bleed-green bug class
 *   (PR #356, #373, #376). They are recomputed from events on pull.
 *   BoardTask is a pure placement record.
 * - For compound Tasks (`type='compound'`), `isCompleted` is written
 *   defensively as `false` for column uniformity (so Firestore + Zod always
 *   see the field) but is never *read* — derive completion at evaluation
 *   time via `evaluateCompound()` instead. Reading `isCompleted` directly
 *   off a compound row is a bug.
 * - UUID primary key (offline creation)
 * - Aggregate stats track usage across boards
 */
export interface Task {
  // Identity
  id: string;                    // UUID (client-generated)
  userId: string;                // Foreign key to users table

  // Core fields
  title: string;                 // Task title (e.g., "Read a book")
  description?: string;          // Optional detailed description
  type: TaskType;                // normal, counting, progress, or compound

  // Counting task fields (only for type='counting')
  action?: string;               // Action verb (e.g., "Read", "Run")
  unit?: string;                 // Unit of measurement (e.g., "pages", "miles")
  maxCount?: number;             // Target count (e.g., 100)

  // Compound-specific fields (only meaningful when type === TaskType.COMPOUND)
  operator?: OperatorType;       // AND | OR | M_OF_N
  threshold?: number;            // Required when operator === 'M_OF_N'
  isOrdered?: boolean;           // Display hint: true → progress-style ordered step list

  /**
   * Phase 6.3 — Achievement-task cross-board reference (specific board).
   * Only meaningful when `type === TaskType.ACHIEVEMENT`. Mutually exclusive
   * with `referencedTemplateId` — Zod refinement on `TaskSchema` rejects
   * rows that set both, and derivation has a defensive precedence rule
   * (board wins) for bad data that slips through anyway. Setting either
   * reference field on a non-ACHIEVEMENT task is rejected at the schema
   * boundary.
   */
  referencedBoardId?: string;
  /**
   * Phase 6.3 — Achievement-task cross-board reference (recurring template).
   * Only meaningful when `type === TaskType.ACHIEVEMENT`. Watches every
   * non-deleted spawn of this template whose `startDate` falls within the
   * parent board's `[startDate, endDate]` window. Mutually exclusive with
   * `referencedBoardId`.
   */
  referencedTemplateId?: string;

  /**
   * Phase 6.3 — Completion trigger for the watched target. Defines what
   * counts as the referenced board (or each in-window spawn for template
   * mode) being "done":
   *   - `BINGO`: target has at least one bingo line (`linesCompleted > 0`)
   *   - `GREENLOG`: target's status is `BoardStatus.COMPLETED`
   *
   * Only meaningful when `type === TaskType.ACHIEVEMENT`. Defaults to
   * `GREENLOG` when unset (matches the pre-trigger shipped behavior).
   * Setting this field on a non-ACHIEVEMENT task is rejected by Zod.
   */
  achievementTrigger?: AchievementTrigger;
  /**
   * Phase 6.3 — Required count of in-window spawns that must meet the
   * `achievementTrigger` for the cell to complete. Only meaningful when
   * `type === TaskType.ACHIEVEMENT` AND `referencedTemplateId` is set
   * (recurring-template mode). For specific-board mode the count is
   * implicitly 1 (a named board either hit the trigger or didn't);
   * this field is ignored.
   *
   * Must be a positive integer. When the in-window spawn set has fewer
   * spawns than `requiredCount`, the cell stays incomplete (mirrors the
   * locked "empty window = incomplete, NOT vacuously true" rule).
   */
  requiredCount?: number;

  // Task linking (for tasks used as progress steps)
  parentStepId?: string;         // References TaskStep.id in parent task
  parentStepIndex?: number;      // Position of step in parent task (0-based)

  // Progress counters (for tasks that contribute to shared counters)
  progressCounters?: TaskProgressCounter[];

  // LIFETIME-CACHE completion state (Windowed Completion §Task caches):
  // library/global reads + the derived-counter carve-out ONLY — never for
  // windowed board rendering (resolve via task_events instead).
  //   - STORED for primitives (NORMAL / COUNTING): the actual value.
  //   - STORED as `false` on compound rows for column uniformity (so the
  //     field is always present in Firestore docs + Zod-validated payloads),
  //     but NEVER READ. Consumers must resolve compound completion via
  //     evaluateCompound(). Reading isCompleted directly off a compound row
  //     is a bug.
  isCompleted: boolean;          // Default false
  completedAt?: string;          // ISO8601
  currentCount?: number;         // For counting tasks (NOTE: moved here from BoardTask)

  // Aggregate stats (denormalized for performance)
  totalCompletions: number;      // ⚠️ NOT currently derived from task_events — stuck at its creation-time
                                 // value (WINDOWED_COMPLETION.md's "becomes real" table row was never
                                 // implemented; user-visible on both task-detail screens). Issue #384.
  totalInstances: number;        // How many boards include this task

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete
  deletedAt?: string;            // ISO8601

  /**
   * Draft-board provenance. `true` when this Task was created inside the
   * board wizard via the deferred-persist path (Bug #85) — i.e. it is
   * "born from a board" rather than created standalone in the Tasks tab.
   *
   * It exists so library-browse surfaces can hide a wizard-born task
   * until its board is "officially created" (active): the visibility
   * rule is *hide iff `createdInWizard` AND the task is placed only on
   * draft boards*. A standalone task (`createdInWizard` false/absent) is
   * never hidden, even if it's added to a draft board; and a wizard-born
   * task becomes visible automatically once any board referencing it goes
   * active (no clearing logic — the rule is fully derived at read time).
   *
   * Absent/false on every task created before this field shipped and on
   * all standalone + copied tasks. Only iOS acts on it today; web
   * round-trips it via sync (a web library filter is a follow-up).
   */
  createdInWizard?: boolean;

  /**
   * P5 — Hub-born counters. `true` marks this COUNTING task as a counter in
   * its own right: it appears in the Counters Hub even with zero linked
   * tasks, and — when goal-less (`maxCount` absent) — is excluded from
   * library-browse surfaces (it lives in the hub; board presence goes
   * through linked member tasks). Set by the hub "+ New counter" create and
   * promote-at-dedupe paths only; excluded from `UpdateTaskInput` (the
   * `lastSpawnedWindowKey` precedent). Optional/absent on all pre-P5 rows;
   * forward-compatible decode (`Board.isCore` precedent).
   * Canonical design: docs/SHARED_COUNTERS.md §P5.
   */
  isCounter?: boolean;

  /**
   * Counters UX refresh (R2). The last amount the user logged against this
   * counter — becomes the pre-selected "default" amount chip on the Hub's
   * "+ Log" pill and Counter Detail's amount-chip row (alongside the fixed
   * 1 / 25 / # options). Only meaningful on a source counting task (a plain
   * or hub-born counter, i.e. `sharedCounterId == null`); derived (linked)
   * tasks never set it — logging always happens through the source.
   *
   * Positive integer when present; absent means "no log yet" and callers
   * fall back to `1`. Synced per-row LWW like every other Task field.
   * Canonical design: docs/SHARED_COUNTERS.md §Counters UX refresh →
   * Amount logging.
   */
  defaultLogAmount?: number;

  // Phase 6.Y — Timeboxed Tasks. All three fields are optional; when
  // ALL are absent the task is "indefinite" (never expires, always
  // shows in the Tasks tab). When `endDate` is set, the Tasks tab
  // default-hides the task once `now > endDate` (a "Show expired"
  // toggle reveals it). Wizard-initiated creates inherit these from
  // the board being built; standalone quick-add creates default to
  // indefinite (user can override in the New Task sheet). Tasks
  // existing pre-migration are backfilled from their most-recent
  // BoardTask placement during Dexie v9 / GRDB v14 upgrade.
  //
  // No DB-level constraint enforcing all-three-or-none — the
  // backfill writes them consistently and new creates default to
  // inherited-from-board, so inconsistency is a caller bug.
  timeframe?: Timeframe;         // DAILY / WEEKLY / MONTHLY / YEARLY / CUSTOM
  startDate?: string;            // ISO8601
  endDate?: string;              // ISO8601

  /**
   * Phase 2 — Shared Counters. Points at the source counting task whose
   * `currentCount` drives this task's displayed value via
   * `deriveDisplayedCount()`. Null/undefined for non-linked tasks.
   * Only meaningful when `type === TaskType.COUNTING`.
   *
   * The FK is stored in SQLite / IndexedDB as a plain TEXT column with no
   * database-level FOREIGN KEY constraint enforced at runtime (soft-delete
   * semantics make hard constraints unworkable). Callers are responsible for
   * not pointing at a deleted source.
   */
  sharedCounterId?: string | null;

  /**
   * Phase 2 — Shared Counters. The source task's `currentCount` at the
   * moment this task was linked. Used by `deriveDisplayedCount()`:
   *   - "Inherit" mode: `baseline = 0` → displayed = source.currentCount.
   *   - "Start from zero" mode: `baseline = source.currentCount_at_link_time`
   *     → displayed = source.currentCount − baseline.
   *
   * Must be set (non-negative integer) when `sharedCounterId` is non-null,
   * and must be null/undefined when `sharedCounterId` is null/undefined.
   * The Zod refinement on `CreateTaskInputSchema` / `UpdateTaskInputSchema`
   * enforces this shape invariant.
   */
  baseline?: number | null;

  /**
   * RETIRED (Windowed Completion). Phase 4's shared-counter additive-merge
   * common-ancestor baseline. The additive-merge conflict resolver it fed was
   * retired — counting-task conflicts now resolve by union-of-events, not by
   * merging `currentCount` (docs/WINDOWED_COMPLETION.md §Shared counters
   * interaction). Nothing writes or reads this field anymore (WC PR B stopped
   * stamping it; WC PR D deleted the merge machinery).
   *
   * The field is kept in the type + Zod schema + persisted columns for decode
   * compatibility — old synced rows and pre-WC clients may still carry it, so
   * dropping it would break decode. It is inert residue; do not re-wire it.
   */
  lastSyncedCount?: number | null;
}

/**
 * TaskProgressCounter - Link task to progress counter
 *
 * Allows task to contribute to shared counter
 */
export interface TaskProgressCounter {
  counterId: string;             // FK to progress_counters table
  targetValue: number;           // Target for this task instance
  unit?: string;                 // Override unit if different from counter
}

/**
 * Progress task step (embedded in progress tasks)
 *
 * Note: Steps are stored separately in task_steps table,
 * referenced by taskId
 */
export interface TaskStep {
  id: string;                    // UUID
  taskId: string;                // Foreign key to tasks table
  stepIndex: number;             // Order of step (0-based)
  title: string;                 // Step description
  type: TaskType;                // normal or counting (progress steps can't have sub-steps)

  // Counting step fields (only for type='counting')
  action?: string;
  unit?: string;
  maxCount?: number;

  // Step linking (for steps that reference existing tasks)
  linkedTaskId?: string;         // References separate Task document

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete
  deletedAt?: string;            // ISO8601
}

/**
 * Task creation input
 */
export interface CreateTaskInput {
  title: string;
  description?: string;
  type: TaskType;
  action?: string;
  unit?: string;
  maxCount?: number;
  steps?: CreateTaskStepInput[]; // Only for progress tasks
  /** Phase 6.3 — required (XOR with `referencedTemplateId`) when
   *  `type === TaskType.ACHIEVEMENT`. Forbidden on all other types. */
  referencedBoardId?: string;
  /** Phase 6.3 — required (XOR with `referencedBoardId`) when
   *  `type === TaskType.ACHIEVEMENT`. Forbidden on all other types. */
  referencedTemplateId?: string;
  /** Phase 6.3 — completion trigger (default `GREENLOG`). Only
   *  meaningful when `type === TaskType.ACHIEVEMENT`. */
  achievementTrigger?: AchievementTrigger;
  /** Phase 6.3 — required count of in-window spawns hitting the trigger.
   *  Required (positive integer) when `referencedTemplateId` is set;
   *  ignored for specific-board mode and rejected on non-ACHIEVEMENT. */
  requiredCount?: number;

  /** Phase 6.Y — Timeboxed Tasks. Optional. When set, the resulting
   *  Task carries its own temporal anchor for the Tasks-tab
   *  default-hide-expired filter. Wizard creates set this from the
   *  board's timeframe + dates; standalone quick-add omits these
   *  (indefinite). User can override in the New Task sheet. */
  timeframe?: Timeframe;
  startDate?: string;
  endDate?: string;

  /**
   * Phase 2 — Shared Counters. When set, the new task is a *linked*
   * derived counter that reads its displayed value from the source task
   * identified by `sharedCounterId`. Only valid on `type === COUNTING`.
   *
   * See `Task.sharedCounterId` for the full invariant documentation.
   */
  sharedCounterId?: string | null;

  /**
   * Phase 2 — Shared Counters. The baseline offset for the linked derived
   * counter. Must be provided (>= 0) when `sharedCounterId` is set, and
   * must be absent when `sharedCounterId` is absent. See `Task.baseline`.
   */
  baseline?: number | null;

  /**
   * P5 — Hub-born counters. See `Task.isCounter` for the full invariant
   * documentation. Canonical design: docs/SHARED_COUNTERS.md §P5.
   */
  isCounter?: boolean;
}

/**
 * Task step creation input
 */
export interface CreateTaskStepInput {
  title: string;
  type: TaskType;
  action?: string;
  unit?: string;
  maxCount?: number;
}

/**
 * Task update input
 */
export interface UpdateTaskInput {
  title?: string;
  description?: string;
  // Note: Can't change type after creation
  /**
   * Phase 6.3 — only meaningful when the underlying Task is ACHIEVEMENT.
   * `null` sentinel clears the field; `undefined` leaves it unchanged.
   * Mutual exclusion with `referencedTemplateId` is enforced at the
   * write helper / Zod refinement layer.
   */
  referencedBoardId?: string | null;
  /** See `referencedBoardId`. Mutually exclusive. */
  referencedTemplateId?: string | null;
  /** Phase 6.3 — completion trigger. `null` clears (caller almost
   *  never wants this since the field is required when ACHIEVEMENT;
   *  helper-layer re-validation will reject the cleared state). */
  achievementTrigger?: AchievementTrigger | null;
  /** Phase 6.3 — required spawn count. `null` clears. Only meaningful
   *  in recurring-template mode. */
  requiredCount?: number | null;

  /** Phase 6.Y — Timeboxed Tasks. `null` clears the field (sets task
   *  to indefinite); `undefined` leaves unchanged. All three fields
   *  travel together by convention (the New Task / edit form sends
   *  them as a set), but Zod does not enforce the invariant — callers
   *  are responsible for keeping them consistent. */
  timeframe?: Timeframe | null;
  startDate?: string | null;
  endDate?: string | null;

  /**
   * Phase 2 — Shared Counters. `null` clears the shared-counter link
   * (unlinks the task); `undefined` leaves unchanged.
   * When setting a non-null value both `sharedCounterId` and `baseline`
   * must be provided together — the Zod refinement enforces co-presence.
   */
  sharedCounterId?: string | null;

  /**
   * Phase 2 — Shared Counters. `null` clears the baseline (use only in
   * conjunction with clearing `sharedCounterId`). See `Task.baseline`.
   */
  baseline?: number | null;
}

/**
 * Inline definition for an auto-created child Task. Compound children created
 * inline must be primitives — nested compounds must be created standalone first
 * and referenced via `childTaskId`.
 */
export interface AutoCreateCompoundChildTask {
  type: TaskType.NORMAL | TaskType.COUNTING;
  title: string;
  description?: string;
  /** Counting-task fields (only when type='counting'). */
  action?: string;
  unit?: string;
  maxCount?: number;
  /**
   * R1 counters refresh — auto-link (docs/SHARED_COUNTERS.md, counters UX
   * refresh spec). When the counting child's (action, unit) pair matches an
   * existing counter and the user hasn't opted out via the "Don't link"
   * hint, the caller sets this to the matched counter's source Task id so
   * the inline-created child is born already linked (same semantics as
   * `Task.sharedCounterId`). Must be paired with `baseline`.
   */
  sharedCounterId?: string | null;
  /**
   * The auto-link baseline — always the source counter's lifetime count at
   * creation time ("start fresh": the new task's own window begins at 0
   * regardless of the source's history). See `Task.baseline`. Must be
   * provided when `sharedCounterId` is set.
   */
  baseline?: number | null;
}

/**
 * One child of a compound being created. The caller supplies either an
 * existing Task id or an inline new-task definition — never both.
 */
export interface CreateCompoundChildEntry {
  childTaskId?: string;
  autoCreate?: AutoCreateCompoundChildTask;
}

/**
 * Input for creating a compound task (replaces both progress-create and
 * composite-create paths).
 *
 * Each child entry references either an existing Task (`childTaskId`) OR
 * provides an inline `autoCreate` definition for a new primitive Task to be
 * created in the same write transaction. Exactly one of the two must be set.
 */
export interface CreateCompoundTaskInput {
  title: string;
  description?: string;
  operator: OperatorType;
  /** Required when operator === 'M_OF_N'. */
  threshold?: number;
  /** Display hint: true → renders as ordered "step list" (former Progress UX). */
  isOrdered: boolean;
  children: CreateCompoundChildEntry[];
  /** Phase 6.Y — Timeboxed Tasks. Optional. When provided the parent
   *  compound + every inline-created child Task inherit this triple. */
  timeframe?: Timeframe;
  startDate?: string;
  endDate?: string;
}
