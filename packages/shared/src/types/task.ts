import { AchievementTrigger, OperatorType, TaskType, Timeframe } from '../constants/enums';

/**
 * Task - Reusable task definition
 *
 * Design principles:
 * - Tasks are reusable across multiple boards
 * - Global completion state lives on Task itself (`isCompleted`, `currentCount`,
 *   `completedAt`). Completing a task on any board reflects on every board it
 *   appears on. BoardTask is now a pure placement record.
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

  // Global completion state
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
  totalCompletions: number;      // How many times completed across all boards
  totalInstances: number;        // How many boards include this task

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete
  deletedAt?: string;            // ISO8601

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
   * Phase 4 — Shared Counter Sync. The `currentCount` value that was last
   * confirmed pushed to (or pulled from) Firestore for this Task. Used as the
   * common-ancestor baseline for additive-merge conflict resolution:
   *
   *   mergedCount = remote.currentCount + (local.currentCount - lastSyncedCount)
   *
   * Set after every successful push of this counting Task and after every
   * remote-wins pull. Not bumped on local increments — only on confirmed
   * Firestore round-trips.
   *
   * When null/undefined (first sync, or Task pre-dates Phase 4 migration):
   * the conflict resolver falls back to plain LWW — no common ancestor is
   * known so additive merge is not safe.
   *
   * Only meaningful on `type === COUNTING` tasks that are shared-counter
   * sources (i.e. at least one other Task has `sharedCounterId === this.id`).
   * Stored on ALL counting tasks for forward-compatibility (if the source
   * designation changes, the field is already present).
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
