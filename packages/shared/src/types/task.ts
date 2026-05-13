import { AchievementTrigger, OperatorType, TaskType } from '../constants/enums';

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
}
