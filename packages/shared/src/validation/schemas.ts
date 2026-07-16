import { z } from 'zod';
import { AchievementTrigger, BoardStatus, TaskType, Timeframe, CenterSquareType, SyncOperationType, SyncStatus, OperatorType } from '../constants/enums';

/**
 * Validation schemas using Zod
 *
 * These schemas validate user input and ensure data integrity
 * before saving to local database or syncing to Firestore
 */

// ===== Board Schemas =====

export const BoardSizeSchema = z.union([z.literal(3), z.literal(4), z.literal(5)]);

/**
 * Accepts ISO8601 with UTC (`Z`), offset (`+02:00`), or local (no suffix).
 *
 * Boards' `startDate`/`endDate` are written by `toLocalISO()` for calendar-
 * bound boards (no timezone suffix), but Firestore round-trips of `Timestamp`
 * values produce full UTC with `Z`. Both must parse or the pull path rejects
 * every real board. Creation/update timestamps always use `new Date()
 * .toISOString()` and stay on the stricter `.datetime()` default.
 */
const FlexibleDateTime = z.string().datetime({ local: true, offset: true });

export const CreateBoardInputSchema = z.object({
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  boardSize: BoardSizeSchema,
  timeframe: z.nativeEnum(Timeframe),
  startDate: FlexibleDateTime,
  // Absent for INDEFINITE boards (no end date). When present it must be
  // after startDate (see refine below).
  endDate: FlexibleDateTime.optional(),
  centerSquareType: z.nativeEnum(CenterSquareType),
  centerSquareCustomName: z.string().max(100).optional(),
  centerTaskId: z.string().uuid().optional(),
  isRandomized: z.boolean(),
}).refine(
  (data) => data.endDate == null || new Date(data.endDate) > new Date(data.startDate),
  { message: 'End date must be after start date' }
).refine(
  (data) => {
    if (data.centerSquareType === CenterSquareType.CUSTOM_FREE) {
      return data.centerSquareCustomName !== undefined && data.centerSquareCustomName.length > 0;
    }
    return true;
  },
  { message: 'centerSquareCustomName is required when centerSquareType is custom_free' }
).refine(
  (data) => {
    if (data.centerSquareType === CenterSquareType.CHOSEN) {
      return data.centerTaskId !== undefined;
    }
    return true;
  },
  { message: 'centerTaskId is required when centerSquareType is chosen' }
);

export const UpdateBoardInputSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  description: z.string().max(500).optional(),
  status: z.nativeEnum(BoardStatus).optional(),
});

export const BoardSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  status: z.nativeEnum(BoardStatus),
  boardSize: BoardSizeSchema,
  timeframe: z.nativeEnum(Timeframe),
  startDate: FlexibleDateTime,
  endDate: FlexibleDateTime.optional(),   // Absent for INDEFINITE boards
  centerSquareType: z.nativeEnum(CenterSquareType),
  centerSquareCustomName: z.string().max(100).optional(),
  centerTaskId: z.string().uuid().optional(),
  isRandomized: z.boolean(),
  totalTasks: z.number().int().min(0),
  completedTasks: z.number().int().min(0),
  linesCompleted: z.number().int().min(0),
  completedLineIds: z.array(z.string()).optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  completedAt: z.string().datetime().optional(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
  // Phase 6.2 provenance — additive, optional. Pre-6.2 peers without
  // this field decode unchanged; the spawn path sets it on insert.
  spawnedFromTemplateId: z.string().uuid().optional(),
  // Phase 6.1 core-board marker. Defaulted so sync-pulled rows from
  // older clients (without the field) decode as ad-hoc / non-core.
  isCore: z.boolean().default(false),
  // Windowed Completion — board sealing (docs §Sealing → Board schema delta).
  // All additive + optional so pre-sealing peers' rows decode unchanged.
  // `sealedCompletedCells` is bounded by boardSize² in practice; we don't
  // enforce an upper length here (a stale/oversized array self-heals via the
  // pull-path re-derivation).
  sealedAt: FlexibleDateTime.optional(),
  sealedCompletedCells: z.array(z.number().int().min(0)).optional(),
  activatedAt: FlexibleDateTime.optional(),
});

// ===== Task Schemas =====

export const CreateTaskStepInputSchema = z.object({
  title: z.string().min(1).max(200),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
});

/**
 * Phase 6.3 — `referencedBoardId` and `referencedTemplateId` rules on Task:
 *   1. Both unset OR exactly one set; never both. (Mutually exclusive.)
 *   2. When `type === ACHIEVEMENT`: exactly one MUST be set.
 *   3. When `type !== ACHIEVEMENT`: neither may be set.
 * `derivationPass.ts` has a defensive precedence rule (`referencedBoardId`
 * wins) for the case where bad data slips through anyway.
 */
const referencedFieldsOnTaskMutuallyExclusive = (data: {
  referencedBoardId?: string | null;
  referencedTemplateId?: string | null;
}): boolean => !(data.referencedBoardId && data.referencedTemplateId);

const achievementRequiresReference = (data: {
  type?: TaskType;
  referencedBoardId?: string | null;
  referencedTemplateId?: string | null;
}): boolean => {
  if (data.type !== TaskType.ACHIEVEMENT) return true;
  // Treat `null` as "explicitly cleared" — same as absent. The XOR demands
  // *some* truthy value on one side.
  const hasBoard = data.referencedBoardId != null && data.referencedBoardId !== '';
  const hasTpl = data.referencedTemplateId != null && data.referencedTemplateId !== '';
  return hasBoard || hasTpl;
};

const referenceFieldsForbiddenOnNonAchievement = (data: {
  type?: TaskType;
  referencedBoardId?: string | null;
  referencedTemplateId?: string | null;
}): boolean => {
  if (data.type === undefined || data.type === TaskType.ACHIEVEMENT) return true;
  return !(data.referencedBoardId || data.referencedTemplateId);
};

/**
 * Phase 2 — Shared Counters. `sharedCounterId` and `baseline` must be
 * co-present or both absent:
 *   - Both null/undefined → valid (non-linked task).
 *   - sharedCounterId set + baseline set (>= 0 integer) → valid (linked task).
 *   - sharedCounterId set + baseline absent/null → REJECTED.
 *   - sharedCounterId absent/null + baseline set → REJECTED.
 *
 * Shape-only refinement. No cross-row existence check here — that's Phase 3.
 */
const sharedCounterFieldsConsistent = (data: {
  sharedCounterId?: string | null;
  baseline?: number | null;
}): boolean => {
  const hasId = data.sharedCounterId != null && data.sharedCounterId !== '';
  const hasBaseline = data.baseline != null;
  // Both present or both absent.
  if (hasId !== hasBaseline) return false;
  // baseline must be a non-negative integer when present.
  if (hasBaseline && data.baseline !== undefined && data.baseline !== null) {
    if (!Number.isInteger(data.baseline) || data.baseline < 0) return false;
  }
  return true;
};

/**
 * Phase 6.3 — `achievementTrigger` is only valid on ACHIEVEMENT tasks.
 * (Setting it on NORMAL/COUNTING/COMPOUND is rejected.) When `type` is
 * absent from the patch, skip the check — helper-layer re-validation
 * covers the post-merge state.
 */
const triggerForbiddenOnNonAchievement = (data: {
  type?: TaskType;
  achievementTrigger?: AchievementTrigger | null;
}): boolean => {
  if (data.type === undefined || data.type === TaskType.ACHIEVEMENT) return true;
  return data.achievementTrigger == null;
};

/**
 * Phase 6.3 — `requiredCount` is only meaningful on ACHIEVEMENT tasks
 * in recurring-template mode. Specific-board mode and non-ACHIEVEMENT
 * types must leave it unset. Recurring-template ACHIEVEMENT MUST set
 * it (positive integer; the count field itself constrains > 0 via the
 * schema). When `type` is absent from the patch, skip — helper layer
 * re-validates merged state.
 */
const requiredCountRulesOk = (data: {
  type?: TaskType;
  referencedBoardId?: string | null;
  referencedTemplateId?: string | null;
  requiredCount?: number | null;
}): boolean => {
  if (data.type === undefined) return true;
  if (data.type !== TaskType.ACHIEVEMENT) return data.requiredCount == null;
  // ACHIEVEMENT: must be set iff template mode.
  if (data.referencedTemplateId != null && data.referencedTemplateId !== '') {
    return data.requiredCount != null && data.requiredCount > 0;
  }
  // specific-board mode or no reference yet: requiredCount must be unset.
  return data.requiredCount == null;
};

export const CreateTaskInputSchema = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  steps: z.array(CreateTaskStepInputSchema).optional(),
  referencedBoardId: z.string().uuid().optional(),
  referencedTemplateId: z.string().uuid().optional(),
  achievementTrigger: z.nativeEnum(AchievementTrigger).optional(),
  requiredCount: z.number().int().positive().optional(),
  // Phase 6.Y — Timeboxed Tasks. All optional; absent ⇒ indefinite.
  // No all-three-or-none refinement; callers (wizard-create + edit)
  // are responsible for keeping them consistent.
  timeframe: z.nativeEnum(Timeframe).optional(),
  startDate: z.string().optional(),
  endDate: z.string().optional(),
  // Phase 2 — Shared Counters. Co-present or both absent.
  // Refinement `sharedCounterFieldsConsistent` enforces the shape invariant.
  // UUID constraint matches how other nullable ID fields are typed in this
  // file (e.g. `referencedBoardId`, `centerTaskId`) — rejects empty strings.
  sharedCounterId: z.string().uuid().nullable().optional(),
  baseline: z.number().int().min(0).nullable().optional(),
  // P5 — Hub-born counters. See `Task.isCounter` for the full invariant
  // documentation. Canonical design: docs/SHARED_COUNTERS.md §P5.
  isCounter: z.boolean().optional(),
}).refine(
  (data) => {
    // Counting tasks must have action, unit, and maxCount — except hub-born
    // counters (isCounter), which are goal-less accumulators (P5).
    if (data.type === TaskType.COUNTING) {
      return data.action && data.unit && (data.maxCount || data.isCounter === true);
    }
    return true;
  },
  { message: 'Counting tasks must have action, unit, and maxCount (unless isCounter)' }
).refine(
  referencedFieldsOnTaskMutuallyExclusive,
  { message: 'Task.referencedBoardId and referencedTemplateId are mutually exclusive — at most one may be set' },
).refine(
  achievementRequiresReference,
  { message: "Achievement tasks must set exactly one of referencedBoardId or referencedTemplateId" },
).refine(
  referenceFieldsForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set referencedBoardId or referencedTemplateId" },
).refine(
  triggerForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set achievementTrigger" },
).refine(
  requiredCountRulesOk,
  { message: "requiredCount must be a positive integer when referencedTemplateId is set, and must be unset otherwise" },
).refine(
  sharedCounterFieldsConsistent,
  { message: "sharedCounterId and baseline must both be set (with baseline >= 0) or both be absent/null" },
).refine(
  (data) => data.isCounter !== true || data.type === TaskType.COUNTING,
  { message: 'Only COUNTING tasks may set isCounter' },
).refine(
  (data) => data.isCounter !== true || data.sharedCounterId == null,
  { message: 'A derived (linked) counting task cannot be a counter' },
);
// Note: post-unification, Progress tasks are created via
// `CreateCompoundTaskInputSchema` (compound + isOrdered=true). This schema
// only accepts NORMAL / COUNTING / COMPOUND / ACHIEVEMENT — no Progress branch needed.

export const UpdateTaskInputSchema = z.object({
  title: z.string().min(1).max(200).optional(),
  description: z.string().max(1000).optional(),
  /**
   * Phase 6.3 — `type` is optional on update because callers usually
   * patch other fields and leave the type alone. When present, the
   * refinements below check `referencedBoardId` / `referencedTemplateId`
   * against the patched type. When absent, the refinements skip the
   * type-match check (the helper layer is expected to fetch the
   * existing row and re-validate against its post-merge state — see
   * `updateTask` in `apps/web/src/db/operations/tasks.ts`).
   */
  type: z.nativeEnum(TaskType).optional(),
  // `null` sentinel clears the field; `undefined` leaves it untouched.
  referencedBoardId: z.string().uuid().nullable().optional(),
  referencedTemplateId: z.string().uuid().nullable().optional(),
  achievementTrigger: z.nativeEnum(AchievementTrigger).nullable().optional(),
  requiredCount: z.number().int().positive().nullable().optional(),
  // Phase 6.Y — Timeboxed Tasks update.
  timeframe: z.nativeEnum(Timeframe).nullable().optional(),
  startDate: z.string().nullable().optional(),
  endDate: z.string().nullable().optional(),
  // Phase 2 — Shared Counters. `null` clears; `undefined` leaves unchanged.
  // UUID constraint matches CreateTaskInputSchema and other nullable ID fields
  // (e.g. referencedBoardId/referencedTemplateId) — rejects empty strings.
  sharedCounterId: z.string().uuid().nullable().optional(),
  baseline: z.number().int().min(0).nullable().optional(),
}).refine(
  referencedFieldsOnTaskMutuallyExclusive,
  { message: 'Task.referencedBoardId and referencedTemplateId are mutually exclusive — at most one may be set' },
).refine(
  achievementRequiresReference,
  { message: "Achievement tasks must set exactly one of referencedBoardId or referencedTemplateId" },
).refine(
  referenceFieldsForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set referencedBoardId or referencedTemplateId" },
).refine(
  triggerForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set achievementTrigger" },
).refine(
  requiredCountRulesOk,
  { message: "requiredCount must be a positive integer when referencedTemplateId is set, and must be unset otherwise" },
).refine(
  sharedCounterFieldsConsistent,
  { message: "sharedCounterId and baseline must both be set (with baseline >= 0) or both be absent/null" },
).refine(
  // Issue #3: reject asymmetric null patches on UPDATE. If baseline is being
  // explicitly cleared (null) but sharedCounterId is still set (non-null), the
  // resulting row would be inconsistent. The `sharedCounterFieldsConsistent`
  // refinement above catches the symmetric case; this one catches the patch-
  // specific asymmetry where one sentinel is null and the other is a value.
  (data) => {
    const idCleared = data.sharedCounterId === null;
    const baselineCleared = data.baseline === null;
    // Both cleared together → valid (symmetric clear, caught by the refine above).
    // baseline cleared but sharedCounterId still set → invalid.
    if (baselineCleared && !idCleared) return false;
    // sharedCounterId cleared but baseline still set → invalid.
    if (idCleared && !baselineCleared && data.baseline !== undefined) return false;
    return true;
  },
  { message: "Clearing baseline requires clearing sharedCounterId in the same patch, and vice versa" },
);

// ===== Compound creation input =====

export const AutoCreateCompoundChildTaskSchema = z.object({
  type: z.enum([TaskType.NORMAL, TaskType.COUNTING]),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  action: z.string().min(1).max(50).optional(),
  unit: z.string().min(1).max(50).optional(),
  maxCount: z.number().int().positive().optional(),
}).refine(
  (data) => {
    if (data.type === TaskType.COUNTING) {
      return data.action !== undefined && data.unit !== undefined && data.maxCount !== undefined;
    }
    return true;
  },
  { message: 'Counting child tasks require action, unit, and maxCount' },
);

export const CreateCompoundChildEntrySchema = z.object({
  childTaskId: z.string().uuid().optional(),
  autoCreate: AutoCreateCompoundChildTaskSchema.optional(),
}).refine(
  (data) => (data.childTaskId !== undefined) !== (data.autoCreate !== undefined),
  { message: 'CreateCompoundChildEntry must specify exactly one of childTaskId or autoCreate' },
);

export const CreateCompoundTaskInputSchema = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  operator: z.nativeEnum(OperatorType),
  threshold: z.number().int().positive().optional(),
  isOrdered: z.boolean(),
  children: z.array(CreateCompoundChildEntrySchema).min(2),
  // Phase 6.Y — Timeboxed Tasks. Optional; when set, the parent
  // compound AND all inline-created children inherit this triple at
  // creation time (see createCompound in db/operations/tasks.ts).
  timeframe: z.nativeEnum(Timeframe).optional(),
  startDate: z.string().optional(),
  endDate: z.string().optional(),
}).refine(
  (data) => {
    if (data.operator === OperatorType.M_OF_N) {
      return data.threshold !== undefined && data.threshold >= 1 && data.threshold <= data.children.length;
    }
    return true;
  },
  { message: "operator='M_OF_N' requires threshold in [1, children.length]" },
).refine(
  (data) => {
    // No duplicate childTaskIds.
    const ids = data.children.map((c) => c.childTaskId).filter((id): id is string => id !== undefined);
    return new Set(ids).size === ids.length;
  },
  { message: 'Compound children must not contain duplicate childTaskId references' },
);

export const TaskProgressCounterSchema = z.object({
  counterId: z.string().uuid(),
  targetValue: z.number().positive(),
  unit: z.string().max(50).optional(),
});

export const TaskSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  // Compound task fields
  operator: z.nativeEnum(OperatorType).optional(),
  threshold: z.number().int().positive().optional(),
  isOrdered: z.boolean().optional(),
  // Phase 6.3 — Achievement-task cross-board references. Only meaningful
  // when `type === ACHIEVEMENT`. Mutually exclusive and required-XOR'd on
  // achievement tasks; forbidden on every other type. The refinements at
  // the bottom of the schema enforce all three rules — when a remote
  // payload arrives via the sync pull, the pull validator (PR Phase 3.5)
  // calls this schema and rejects bad rows before they hit the local DB.
  referencedBoardId: z.string().uuid().optional(),
  referencedTemplateId: z.string().uuid().optional(),
  // Phase 6.3 — completion trigger. Optional at the schema layer so
  // non-ACHIEVEMENT rows can omit the field; derivation defaults to
  // `GREENLOG` at read time when undefined (matches the pre-trigger
  // shipped behavior + the iOS Codable defensive decode).
  achievementTrigger: z.nativeEnum(AchievementTrigger).optional(),
  // Phase 6.3 — required count of in-window spawns hitting the
  // trigger. Required (positive integer) when `referencedTemplateId`
  // is set, forbidden otherwise. Enforced by the `requiredCountRulesOk`
  // refinement below.
  requiredCount: z.number().int().positive().optional(),
  parentStepId: z.string().uuid().optional(),
  parentStepIndex: z.number().int().min(0).optional(),
  progressCounters: z.array(TaskProgressCounterSchema).optional(),
  totalCompletions: z.number().int().min(0),
  totalInstances: z.number().int().min(0),
  // Completion tracking fields (live on Task, not BoardTask).
  // `isCompleted` defaults to `false` on decode so pre-unification Firestore
  // docs (written before global-completion landed) still pass pull validation
  // on a fresh device. Mirrors iOS Task.swift's `decodeIfPresent ?? false`
  // defensive decode at line 170. Without this default, first-sync against a
  // project with stale remote docs would skip every legacy Task.
  isCompleted: z.boolean().default(false),
  completedAt: z.string().datetime().optional(),
  currentCount: z.number().int().nonnegative().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
  // Phase 6.Y — Timeboxed Tasks. All optional; absent ⇒ indefinite.
  // No DB-level constraint requiring all-three-or-none — the backfill
  // migration writes them consistently and new creates default to
  // inherited-from-board, so inconsistency is a caller bug. Loose
  // string for dates (not `.datetime()`) so the migration can write
  // a `YYYY-MM-DD` shape inherited verbatim from `Board.startDate`/`endDate`.
  timeframe: z.nativeEnum(Timeframe).optional(),
  startDate: z.string().optional(),
  endDate: z.string().optional(),
  // Phase 2 — Shared Counters. `sharedCounterId` points at the source counting
  // task whose `currentCount` drives this task's displayed value.
  sharedCounterId: z.string().uuid().nullable().optional(),
  // Phase 2 — Shared Counters. Baseline offset (source count at link time).
  baseline: z.number().int().min(0).nullable().optional(),
  // RETIRED (Windowed Completion) — Phase 4 additive-merge common-ancestor.
  // Inert residue; nothing reads/writes it (docs/WINDOWED_COMPLETION.md §Shared
  // counters interaction). Kept in the schema for decode compat with old rows.
  lastSyncedCount: z.number().int().nonnegative().nullable().optional(),
  // Draft-board provenance. `true` for wizard-born (deferred-persist)
  // tasks; absent/false for standalone + copied + pre-feature tasks.
  // Library-browse surfaces hide a task iff `createdInWizard` AND it is
  // placed only on draft boards. Optional at the schema layer so legacy
  // and other-platform payloads omit it; must round-trip through sync
  // (z.object strips unknown keys, so it has to be declared here).
  createdInWizard: z.boolean().optional(),
  // P5 — Hub-born counters. See `Task.isCounter` for the full invariant
  // documentation. Canonical design: docs/SHARED_COUNTERS.md §P5.
  isCounter: z.boolean().optional(),
}).refine(
  (data) => {
    // Compound tasks must have an operator.
    if (data.type === TaskType.COMPOUND) {
      return data.operator !== undefined;
    }
    return true;
  },
  { message: "Task with type='compound' must have an operator" },
).refine(
  (data) => {
    // M_OF_N operator requires a threshold.
    if (data.operator === OperatorType.M_OF_N) {
      return data.threshold !== undefined;
    }
    return true;
  },
  { message: "Task with operator='M_OF_N' must have a threshold" },
).refine(
  referencedFieldsOnTaskMutuallyExclusive,
  { message: 'Task.referencedBoardId and referencedTemplateId are mutually exclusive — at most one may be set' },
).refine(
  achievementRequiresReference,
  { message: "Achievement tasks must set exactly one of referencedBoardId or referencedTemplateId" },
).refine(
  referenceFieldsForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set referencedBoardId or referencedTemplateId" },
).refine(
  triggerForbiddenOnNonAchievement,
  { message: "Only ACHIEVEMENT tasks may set achievementTrigger" },
).refine(
  requiredCountRulesOk,
  { message: "requiredCount must be a positive integer when referencedTemplateId is set, and must be unset otherwise" },
);

// ===== TaskEvent Schema (Windowed Completion) =====
//
// docs/WINDOWED_COMPLETION.md §New entity. A synced, soft-deletable
// occurrence row for an event-owning task. Per-row LWW like compoundChildren.
//
// NOTE: the "events only for event-owning tasks" rule (reject compound /
// achievement / derived-counting task ids) CANNOT be enforced here — a
// TaskEvent row carries only `taskId`, not the task's type. That rule lives in
// the shared `isEventOwningTask(task)` predicate, which the write choke points
// call with the Task in hand. This schema enforces the row-shape invariants
// (delta ⇄ kind, occurredAt required, sync-metadata shape) that the pull path
// can validate from the row alone.
export const TaskEventSchema = z
  .object({
    id: z.string().uuid(),
    userId: z.string(),
    taskId: z.string().uuid(),
    kind: z.enum(['completion', 'increment']),
    // Present + non-zero integer on increments; forbidden on completions
    // (enforced by the refinement below).
    delta: z.number().int().optional(),
    occurredAt: z.string().datetime(),
    boardId: z.string().uuid().optional(),
    createdAt: z.string().datetime(),
    updatedAt: z.string().datetime(),
    lastSyncedAt: z.string().datetime().optional(),
    version: z.number().int().min(1),
    isDeleted: z.boolean(),
    deletedAt: z.string().datetime().optional(),
  })
  .refine(
    (data) => {
      if (data.kind === 'increment') {
        return data.delta !== undefined && Number.isInteger(data.delta) && data.delta !== 0;
      }
      // completion
      return data.delta === undefined;
    },
    {
      message:
        "TaskEvent.delta must be a non-zero integer when kind='increment', and must be absent when kind='completion'",
    },
  );

export const TaskStepSchema = z.object({
  id: z.string().uuid(),
  taskId: z.string().uuid(),
  stepIndex: z.number().int().min(0),
  title: z.string().min(1).max(200),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  linkedTaskId: z.string().uuid().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== BoardTask Schemas =====
//
// Phase 6.3 — BoardTask is a pure placement record. The pre-refactor
// achievement-square fields (`isAchievementSquare`, `achievementType`,
// `achievementCount`, `achievementTimeframe`, `achievementProgress`,
// `referencedBoardId`, `referencedTemplateId`) moved to `Task` as part
// of the ACHIEVEMENT-as-TaskType refactor — placements just record where
// the task lives on a board, the rest is derived from the Task itself.

export const CreateBoardTaskInputSchema = z.object({
  boardId: z.string().uuid(),
  taskId: z.string().uuid(),
  row: z.number().int().min(0),
  col: z.number().int().min(0),
  isCenter: z.boolean(),
});

export const BoardTaskSchema = z.object({
  id: z.string().uuid(),
  boardId: z.string().uuid(),
  taskId: z.string().uuid(),
  row: z.number().int().min(0),
  col: z.number().int().min(0),
  isCenter: z.boolean(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
});

// ===== CompoundChild Schemas =====

const compoundChildNoSelfReference = (data: { compoundTaskId: string; childTaskId: string }) =>
  data.compoundTaskId !== data.childTaskId;

const compoundChildSelfReferenceMessage = {
  message: 'CompoundChild must not self-reference (compoundTaskId == childTaskId)',
};

export const CreateCompoundChildInputSchema = z.object({
  compoundTaskId: z.string().uuid(),
  childTaskId: z.string().uuid(),
  childIndex: z.number().int().nonnegative(),
}).refine(compoundChildNoSelfReference, compoundChildSelfReferenceMessage);

export const CompoundChildSchema = z.object({
  id: z.string().uuid(),
  compoundTaskId: z.string().uuid(),
  childTaskId: z.string().uuid(),
  childIndex: z.number().int().nonnegative(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
}).refine(compoundChildNoSelfReference, compoundChildSelfReferenceMessage);

// ===== ProgressCounter Schemas =====

export const CreateProgressCounterInputSchema = z.object({
  name: z.string().min(1).max(100),
  unit: z.string().min(1).max(50),
  targetValue: z.number().positive(),
});

export const UpdateProgressCounterInputSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  currentValue: z.number().min(0).optional(),
  targetValue: z.number().positive().optional(),
});

export const ProgressCounterSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(100),
  unit: z.string().min(1).max(50),
  targetValue: z.number().positive(),
  currentValue: z.number().min(0),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== SyncQueue Schemas =====

export const CreateSyncQueueItemInputSchema = z.object({
  entityType: z.string(),
  entityId: z.string().uuid(),
  operationType: z.nativeEnum(SyncOperationType),
  payload: z.any(),
  priority: z.number().int().optional(),
});

export const SyncQueueItemSchema = z.object({
  id: z.string().uuid(),
  entityType: z.string(),
  entityId: z.string().uuid(),
  operationType: z.nativeEnum(SyncOperationType),
  payload: z.string(), // JSON string
  status: z.nativeEnum(SyncStatus),
  retryCount: z.number().int().min(0),
  lastError: z.string().optional(),
  createdAt: z.string().datetime(),
  lastAttemptAt: z.string().datetime().optional(),
  completedAt: z.string().datetime().optional(),
  priority: z.number().int(),
});

// ===== Composite Task Schemas =====

/**
 * Inline task auto-creation input (used in leaf nodes)
 */
export const AutoCreateTaskInputSchema = z.object({
  type: z.nativeEnum(TaskType),
  title: z.string().min(1).max(200),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
});

/**
 * Recursive composite node input schema.
 *
 * Uses z.lazy() because operator nodes contain children of the same type.
 */
export const CreateCompositeNodeInputSchema: z.ZodType<unknown> = z.lazy(() =>
  z
    .object({
      nodeType: z.enum(['operator', 'leaf']),

      // Operator node fields
      operatorType: z.nativeEnum(OperatorType).optional(),
      threshold: z.number().int().positive().optional(),
      children: z.array(CreateCompositeNodeInputSchema).optional(),

      // Leaf node fields
      taskId: z.string().uuid().optional(),
      childCompositeTaskId: z.string().uuid().optional(),
      autoCreateTask: AutoCreateTaskInputSchema.optional(),
    })
    .refine(
      (data) => {
        if (data.nodeType === 'operator') {
          return (
            data.operatorType !== undefined &&
            Array.isArray(data.children) &&
            data.children.length > 0
          );
        }
        return true;
      },
      { message: 'Operator nodes must have operatorType and at least one child' }
    )
    .refine(
      (data) => {
        if (data.operatorType === OperatorType.M_OF_N) {
          return data.threshold !== undefined && data.threshold > 0;
        }
        return true;
      },
      { message: 'M_OF_N operator must have threshold > 0' }
    )
    .refine(
      (data) => {
        if (
          data.operatorType === OperatorType.M_OF_N &&
          data.threshold !== undefined &&
          Array.isArray(data.children)
        ) {
          return data.threshold <= data.children.length;
        }
        return true;
      },
      { message: 'M_OF_N threshold must be <= number of children' }
    )
    .refine(
      (data) => {
        if (data.nodeType === 'leaf') {
          const count = [data.taskId, data.childCompositeTaskId, data.autoCreateTask].filter(Boolean).length;
          return count === 1;
        }
        return true;
      },
      {
        message:
          'Leaf nodes must have exactly one of taskId, childCompositeTaskId, or autoCreateTask',
      }
    )
    .refine(
      (data) => {
        if (data.nodeType === 'leaf') {
          return !data.children || data.children.length === 0;
        }
        return true;
      },
      { message: 'Leaf nodes cannot have children' }
    )
);

export const CreateCompositeTaskInputSchema = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  rootNode: CreateCompositeNodeInputSchema,
});

export const CompositeTaskSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  rootNodeId: z.string().uuid(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

export const CompositeNodeSchema = z.object({
  id: z.string().uuid(),
  compositeTaskId: z.string().uuid(),
  parentNodeId: z.string().uuid().optional(),
  nodeIndex: z.number().int().min(0),
  nodeType: z.enum(['operator', 'leaf']),
  operatorType: z.nativeEnum(OperatorType).optional(),
  threshold: z.number().int().positive().optional(),
  taskId: z.string().uuid().optional(),
  childCompositeTaskId: z.string().uuid().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== RecurringBoardTemplate Schemas (Phase 6.2) =====

/**
 * Templates exclude `Timeframe.CUSTOM` (no computed window) and
 * `CenterSquareType.CHOSEN` (MVP scope — see types/recurringBoardTemplate.ts).
 * The schema enforces both at the field level so a malformed pull payload
 * is rejected before it reaches the spawn driver.
 */
const RecurringTimeframeSchema = z.union([
  z.literal(Timeframe.DAILY),
  z.literal(Timeframe.WEEKLY),
  z.literal(Timeframe.MONTHLY),
  z.literal(Timeframe.YEARLY),
]);

const RecurringCenterSquareTypeSchema = z.union([
  z.literal(CenterSquareType.FREE),
  z.literal(CenterSquareType.CUSTOM_FREE),
  z.literal(CenterSquareType.NONE),
]);

export const CreateRecurringBoardTemplateInputSchema = z.object({
  name: z.string().trim().min(1).max(120),
  timeframe: RecurringTimeframeSchema,
  boardSize: BoardSizeSchema,
  centerSquareType: RecurringCenterSquareTypeSchema,
  centerSquareCustomName: z.string().max(100).optional(),
  isRandomized: z.boolean(),
  seedTaskIds: z.array(z.string().uuid()).min(1),
  isActive: z.boolean(),
}).refine(
  (data) => {
    if (data.centerSquareType === CenterSquareType.CUSTOM_FREE) {
      // Trim before checking length so a whitespace-only label
      // ('   ') doesn't slip through. The form input layer also
      // trims, but this is the schema-level defense.
      return (
        data.centerSquareCustomName !== undefined &&
        data.centerSquareCustomName.trim().length > 0
      );
    }
    return true;
  },
  { message: 'centerSquareCustomName is required (and must be non-blank) when centerSquareType is custom_free' },
).refine(
  (data) => {
    // No duplicate seedTaskIds — each pool entry must reference a distinct
    // Task. The spawn path treats duplicates as an error class equivalent
    // to "pool too small" (a 25-pool with 5 dups only places 20 unique tasks).
    return new Set(data.seedTaskIds).size === data.seedTaskIds.length;
  },
  { message: 'seedTaskIds must not contain duplicates' },
);

export const UpdateRecurringBoardTemplateInputSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  timeframe: RecurringTimeframeSchema.optional(),
  boardSize: BoardSizeSchema.optional(),
  centerSquareType: RecurringCenterSquareTypeSchema.optional(),
  centerSquareCustomName: z.string().max(100).optional(),
  isRandomized: z.boolean().optional(),
  seedTaskIds: z.array(z.string().uuid()).min(1).optional(),
  isActive: z.boolean().optional(),
}).refine(
  (data) => {
    if (data.seedTaskIds === undefined) return true;
    return new Set(data.seedTaskIds).size === data.seedTaskIds.length;
  },
  { message: 'seedTaskIds must not contain duplicates' },
).refine(
  (data) => {
    // When a partial update sets `centerSquareType` to CUSTOM_FREE, it must
    // also include a non-blank `centerSquareCustomName` in the same patch.
    // Otherwise a syncing peer or malicious client could land a
    // CUSTOM_FREE template with no label, and the spawn path would create
    // boards whose center cell has no displayable text. The schema can't
    // see the existing record's name, so the conservative call is to
    // require both fields to travel together — the form already does so.
    if (data.centerSquareType !== CenterSquareType.CUSTOM_FREE) return true;
    return (
      data.centerSquareCustomName !== undefined &&
      data.centerSquareCustomName.trim().length > 0
    );
  },
  { message: 'Setting centerSquareType to custom_free requires a non-blank centerSquareCustomName in the same patch' },
);

export const RecurringBoardTemplateSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(120),
  timeframe: RecurringTimeframeSchema,
  boardSize: BoardSizeSchema,
  centerSquareType: RecurringCenterSquareTypeSchema,
  centerSquareCustomName: z.string().max(100).optional(),
  isRandomized: z.boolean(),
  seedTaskIds: z.array(z.string().uuid()),
  lastSpawnedWindowKey: z.string().nullable(),
  isActive: z.boolean(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== DefaultPool Schemas (Phase 6.X — Default Pools) =====

/**
 * DefaultPools follow the same timeframe constraint as templates:
 * `Timeframe.CUSTOM` is excluded because a "default pool per recurring
 * timeframe" has no semantic for custom-window boards. Reuses
 * `RecurringTimeframeSchema` above for parity.
 *
 * `taskIds` MAY be empty — a user can set up a pool, clear it, leave it
 * empty, and later refill it without first deleting + recreating the
 * pool. The wizard prefill path tolerates empty pools (no-op).
 */
export const CreateDefaultPoolInputSchema = z.object({
  timeframe: RecurringTimeframeSchema,
  taskIds: z.array(z.string().uuid()),
}).refine(
  (data) => new Set(data.taskIds).size === data.taskIds.length,
  { message: 'taskIds must not contain duplicates' },
);

export const UpdateDefaultPoolInputSchema = z.object({
  taskIds: z.array(z.string().uuid()).optional(),
}).refine(
  (data) => {
    if (data.taskIds === undefined) return true;
    return new Set(data.taskIds).size === data.taskIds.length;
  },
  { message: 'taskIds must not contain duplicates' },
);

export const DefaultPoolSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  timeframe: RecurringTimeframeSchema,
  taskIds: z.array(z.string().uuid()),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== User Schema =====

export const WeekStartDaySchema = z.union([z.literal('monday'), z.literal('sunday')]);

export const DefaultCenterSquareTypeSchema = z.union([
  z.literal(CenterSquareType.FREE),
  z.literal(CenterSquareType.NONE),
]);

export const ThemePreferenceSchema = z.union([
  z.literal('light'),
  z.literal('dark'),
  z.literal('system'),
]);

export const UserPreferencesSchema = z.object({
  weekStartDay: WeekStartDaySchema,
  defaultBoardSize: BoardSizeSchema,
  defaultCenterType: DefaultCenterSquareTypeSchema,
  defaultTimeframe: z.nativeEnum(Timeframe),
  defaultRandomize: z.boolean(),
  defaultCenterCustomName: z.string().max(100),
  theme: ThemePreferenceSchema,
  // Recurring boards (Phase 6.1): optional for forward-compat with older peers
  // that wrote their user doc before these fields existed. mergeUserPreferences
  // fills in the post-6.1d `true` defaults on the pull path; local writes
  // always include them (DEFAULT_USER_PREFERENCES has them set to true).
  recurringDailyEnabled: z.boolean().optional(),
  recurringWeeklyEnabled: z.boolean().optional(),
  recurringMonthlyEnabled: z.boolean().optional(),
  recurringYearlyEnabled: z.boolean().optional(),
  // Board Preferences (Riso Phase 5a): optional for forward-compat with peers
  // that wrote their user doc before these fields existed. mergeUserPreferences
  // fills defaults on the pull path and clamps celebrationIntensity to 1–10.
  celebrationIntensity: z.number().int().min(1).max(10).optional(),
  haptics: z.boolean().optional(),
  expiringReminders: z.boolean().optional(),
  autoArchiveCompleted: z.boolean().optional(),
  // Notifications (Phase 7 — iOS local reminders): optional for forward-compat
  // with peers that wrote their user doc before these fields existed.
  // mergeUserPreferences fills defaults on the pull path and rejects a
  // malformed dailyPlayReminderTime.
  notificationsEnabled: z.boolean().optional(),
  recurringWindowReminders: z.boolean().optional(),
  dailyPlayReminderEnabled: z.boolean().optional(),
  dailyPlayReminderTime: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/)
    .optional(),
});

export const UserSchema = z.object({
  id: z.string(),
  email: z.string().email(),
  displayName: z.string().optional(),
  photoURL: z.string().url().optional(),
  preferences: UserPreferencesSchema.optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
});
