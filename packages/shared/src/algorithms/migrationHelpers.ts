import type { Task, TaskStep } from '../types/task';
import type { CompoundChild } from '../types/compoundChild';
import type { CompositeTask, CompositeNode } from '../types/compositeTask';
import type { TaskEvent, TaskEventKind } from '../types/taskEvent';
import { OperatorType, TaskType } from '../constants/enums';
import { isEventOwningTask } from './taskEvents';
import { uuidv5, OYBC_NAMESPACE } from './uuidv5';

/**
 * Subset of the legacy BoardTask shape carrying only the fields needed for
 * completion backfill. The new BoardTask type no longer has these fields,
 * so this type stands in as the input shape during migration.
 */
export interface LegacyBoardTaskCompletion {
  taskId: string;
  isCompleted: boolean;
  completedAt?: string;
  currentCount?: number;
  /** Per-board step completion array used by progress tasks pre-unification. */
  completedStepIds?: string[];
}

// ─── Progress Task → Compound ──────────────────────────────────────────────

/**
 * Returns the partial Task fields to merge into a legacy progress Task row to
 * convert it into the unified compound shape. Caller does the actual update.
 *
 * Takes no parameter — the conversion is constant per legacy progress row
 * (every progress task becomes `compound + AND + isOrdered=true`). Earlier
 * iterations took a Task argument for context but never read any field; the
 * signature is now parameter-free for clarity.
 *
 * @returns Partial Task fields to apply to the row (type, operator, isOrdered).
 */
export function progressTaskToCompound(): Partial<Task> {
  return {
    type: TaskType.COMPOUND,
    operator: OperatorType.AND,
    isOrdered: true,
    // threshold deliberately omitted — AND has no threshold
  };
}

// ─── TaskStep → CompoundChild ──────────────────────────────────────────────

/**
 * Builds a CompoundChild row from a legacy TaskStep. Caller supplies a
 * client-generated UUID for `id`. The step's `linkedTaskId` becomes the
 * `childTaskId`. If the step has no linkedTaskId, the helper returns null
 * (defensive — every TaskStep should have one per the existing pre-migration
 * invariant, but legacy data may be inconsistent).
 *
 * @param step - The legacy TaskStep row.
 * @param id - Caller-supplied UUID for the new CompoundChild row.
 * @returns A CompoundChild row, or null if step.linkedTaskId is missing.
 */
export function taskStepToCompoundChild(
  step: TaskStep,
  id: string,
): CompoundChild | null {
  if (!step.linkedTaskId) return null;
  return {
    id,
    compoundTaskId: step.taskId,
    childTaskId: step.linkedTaskId,
    childIndex: step.stepIndex,
    createdAt: step.createdAt,
    updatedAt: step.updatedAt,
    lastSyncedAt: step.lastSyncedAt,
    version: 1,
    isDeleted: step.isDeleted,
    deletedAt: step.deletedAt,
  };
}

// ─── CompositeTask → Task ──────────────────────────────────────────────────

/**
 * Builds a unified Task row from a legacy CompositeTask + its root operator
 * CompositeNode. Preserves the CompositeTask's id so existing CompositeNode
 * leaf references (which point at composite_tasks.id) remain valid as
 * CompoundChild.childTaskId values.
 *
 * If the rootOperatorNode is missing or not an operator type, returns null
 * (defensive — surfaces malformed data without crashing the migration).
 *
 * @param ct - The legacy CompositeTask row.
 * @param rootOperatorNode - The root operator CompositeNode for this composite task.
 * @returns A unified Task row, or null if the root node is invalid.
 */
export function compositeTaskToTask(
  ct: CompositeTask,
  rootOperatorNode: CompositeNode | undefined,
): Task | null {
  if (!rootOperatorNode || rootOperatorNode.nodeType !== 'operator' || !rootOperatorNode.operatorType) {
    return null;
  }
  // Defensive: M_OF_N requires a threshold. A legacy composite_tasks root with
  // operatorType='M_OF_N' but a missing/null threshold would migrate into a
  // Task row that fails the TaskSchema refine ("M_OF_N requires threshold")
  // on the next pull validation — the task would be silently dropped on every
  // device while its legacy DELETEs propagate. Skip here so the malformed row
  // is left in legacy storage rather than corrupting the new schema. Caller
  // sees the same `null` return as the missing-root case and logs/skips.
  if (
    rootOperatorNode.operatorType === OperatorType.M_OF_N &&
    (rootOperatorNode.threshold === undefined || rootOperatorNode.threshold === null)
  ) {
    return null;
  }
  return {
    id: ct.id,
    userId: ct.userId,
    title: ct.title,
    description: ct.description,
    type: TaskType.COMPOUND,
    operator: rootOperatorNode.operatorType,
    threshold: rootOperatorNode.operatorType === OperatorType.M_OF_N ? rootOperatorNode.threshold : undefined,
    isOrdered: false,
    isCompleted: false,           // never read on compound rows; field present for column uniformity
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: ct.createdAt,
    updatedAt: ct.updatedAt,
    lastSyncedAt: ct.lastSyncedAt,
    version: ct.version,
    isDeleted: ct.isDeleted,
    deletedAt: ct.deletedAt,
  };
}

// ─── CompositeNode (leaf) → CompoundChild ──────────────────────────────────

/**
 * Builds a CompoundChild row from a legacy leaf CompositeNode. Operator nodes
 * return null — they're discarded under the new schema (operator now lives on
 * the parent Task).
 *
 * Leaves carry exactly one of `taskId` or `childCompositeTaskId`. Whichever is
 * set becomes the new `childTaskId` (since composites move into the tasks
 * table preserving their ids, both end up pointing at a tasks-table row).
 *
 * @param node - The legacy CompositeNode row.
 * @param id - Caller-supplied UUID for the new CompoundChild row.
 * @returns A CompoundChild row, or null if the node is not a valid leaf.
 */
export function compositeNodeToCompoundChild(
  node: CompositeNode,
  id: string,
): CompoundChild | null {
  if (node.nodeType !== 'leaf') return null;
  const childTaskId = node.taskId ?? node.childCompositeTaskId;
  if (!childTaskId) return null;
  return {
    id,
    compoundTaskId: node.compositeTaskId,
    childTaskId,
    childIndex: node.nodeIndex,
    createdAt: node.createdAt,
    updatedAt: node.updatedAt,
    lastSyncedAt: node.lastSyncedAt,
    version: 1,
    isDeleted: node.isDeleted,
    deletedAt: node.deletedAt,
  };
}

// ─── Global completion backfill ────────────────────────────────────────────

export interface CompletionBackfillResult {
  isCompleted: boolean;
  completedAt?: string;
  currentCount?: number;
}

/**
 * Computes the global Task completion state from the legacy per-board rows.
 *
 * Rules:
 *   - isCompleted = true iff any input row has isCompleted=true.
 *   - completedAt = the LATEST completedAt where isCompleted=true. Undefined
 *     if no row was ever complete. Uses latest (not earliest) because under
 *     the post-unification global model, `Task.completedAt` reads as "when
 *     this task became globally complete" — the most recent completion is
 *     the correct anchor for that semantic, especially for tasks that were
 *     un-completed and re-completed across boards.
 *   - currentCount = MAX(currentCount) across all input rows; undefined if no
 *     input row has currentCount defined.
 *
 * For non-counting tasks, callers can ignore the returned currentCount.
 *
 * @param boardTaskRows - Legacy per-board completion records for a single task.
 * @returns Aggregated global completion state.
 */
export function backfillTaskCompletion(
  boardTaskRows: LegacyBoardTaskCompletion[],
): CompletionBackfillResult {
  let isCompleted = false;
  let latestCompletedAt: string | undefined;
  let maxCount: number | undefined;

  for (const row of boardTaskRows) {
    if (row.isCompleted) {
      isCompleted = true;
      if (row.completedAt && (!latestCompletedAt || row.completedAt > latestCompletedAt)) {
        latestCompletedAt = row.completedAt;
      }
    }
    if (row.currentCount !== undefined) {
      maxCount = maxCount === undefined ? row.currentCount : Math.max(maxCount, row.currentCount);
    }
  }

  return {
    isCompleted,
    completedAt: latestCompletedAt,
    currentCount: maxCount,
  };
}

// ─── Step completion backfill ──────────────────────────────────────────────

/**
 * Returns the set of step ids that were ever completed on any board (per
 * legacy `BoardTask.completedStepIds`). The migration uses this to flip the
 * corresponding TaskStep.linkedTaskId Task to globally-complete.
 *
 * @param boardTaskRows - Legacy per-board completion records for a progress task.
 * @returns Set of step ids that appeared in any board's completedStepIds.
 */
export function collectEverCompletedStepIds(
  boardTaskRows: LegacyBoardTaskCompletion[],
): Set<string> {
  const out = new Set<string>();
  for (const row of boardTaskRows) {
    if (!row.completedStepIds) continue;
    for (const id of row.completedStepIds) out.add(id);
  }
  return out;
}

/**
 * Convenience: given the set of ever-completed step ids and a TaskStep, returns
 * whether the step's linked Task should be backfilled as completed.
 *
 * Rule: if the step's id is in `everCompletedStepIds`, return true.
 *
 * @param step - The legacy TaskStep row.
 * @param everCompletedStepIds - Set produced by `collectEverCompletedStepIds`.
 * @returns True if the step's linked Task should be marked globally complete.
 */
export function shouldBackfillStepLinkedTaskAsComplete(
  step: TaskStep,
  everCompletedStepIds: Set<string>,
): boolean {
  return everCompletedStepIds.has(step.id);
}

// ─── Windowed Completion — TaskEvent backfill ──────────────────────────────
//
// docs/WINDOWED_COMPLETION.md §Migration & backfill. Both platforms call these
// from their one-transaction migration so the event ids + timestamps agree
// regardless of which device migrates first. The determinism is what makes the
// union-dedupe converge: same task snapshot → same kind-qualified id.

/**
 * The deterministic, kind-qualified id for a task's backfill event
 * (docs §Migration & backfill): `uuidv5(taskId + '|backfill|' + kind, NS)`.
 *
 * Kind-qualified so a task whose type was edited between two devices'
 * migrations can't collide a `completion` row against an `increment` row.
 * `uuidv5` produces a UUID that satisfies the schema's UUID id constraint.
 *
 * @param taskId The owning task's id.
 * @param kind   `'completion'` (normal) or `'increment'` (counting).
 * @returns A deterministic v5 UUID.
 */
export function backfillTaskEventId(taskId: string, kind: TaskEventKind): string {
  return uuidv5(`${taskId}|backfill|${kind}`, OYBC_NAMESPACE);
}

/**
 * Build the single backfill `TaskEvent` for one non-deleted, event-owning task,
 * or `null` when the task has nothing to backfill / doesn't own events.
 *
 * Rules (docs §Migration & backfill step 2):
 *   - Derived / compound / achievement tasks are skipped (carve-out) → `null`.
 *   - `NORMAL && isCompleted && completedAt` → one `completion` event,
 *     `occurredAt = completedAt`.
 *   - `COUNTING && currentCount > 0` (plain/source only) → one `increment`
 *     event, `delta = currentCount`, `occurredAt = completedAt ?? updatedAt`.
 *   - Otherwise (`NORMAL` never completed, counting at 0, etc.) → `null`.
 *
 * Timestamps come from the **task snapshot, not migration wall-clock**
 * (`createdAt`/`updatedAt = task.updatedAt`): two devices with divergent
 * pre-migration caches mint same-id rows whose LWW tie-break (equal `version`,
 * compare timestamps) selects the one derived from the fresher task state.
 *
 * The returned event carries no `boardId` (backfill has no board provenance)
 * and no `lastSyncedAt`; the caller enqueues it for sync CREATE.
 *
 * @param task The task snapshot to derive an event from.
 * @returns A TaskEvent, or `null` if nothing to backfill.
 */
export function buildBackfillTaskEvent(task: Task): TaskEvent | null {
  if (task.isDeleted) return null;
  if (!isEventOwningTask(task)) return null;

  const base = {
    userId: task.userId,
    taskId: task.id,
    createdAt: task.updatedAt,
    updatedAt: task.updatedAt,
    version: 1,
    isDeleted: false,
  } as const;

  if (task.type === TaskType.NORMAL) {
    if (!task.isCompleted || !task.completedAt) return null;
    return {
      ...base,
      id: backfillTaskEventId(task.id, 'completion'),
      kind: 'completion',
      occurredAt: task.completedAt,
    };
  }

  // COUNTING (plain / source — isEventOwningTask already excluded derived).
  const count = task.currentCount ?? 0;
  if (count <= 0) return null;
  return {
    ...base,
    id: backfillTaskEventId(task.id, 'increment'),
    kind: 'increment',
    delta: count,
    occurredAt: task.completedAt ?? task.updatedAt,
  };
}

// ─── Task Pools + Recurring Boards Rework — P1 migration mint ids ─────────
//
// docs/POOLS_RECURRING.md §Migration. The v16/v25 first-launch backfill
// (`migrationV16.ts` web, `MigrationV25Helpers.swift` iOS) mints a `Pool` +
// (for DefaultPool) a `CoreBoardDefault` per legacy row. Two devices that
// have each locally cached a copy of the SAME `DefaultPool` /
// `RecurringBoardTemplate` row (pre-sync, or synced-then-migrated
// independently before either device saw the other's migration output)
// would otherwise mint DIFFERENT random ids for what is conceptually the
// same derived row — sync then converges on TWO Pool/CoreBoardDefault docs
// instead of one. `uuidv5`, keyed off the SOURCE row's stable id, makes both
// devices derive the identical id, so sync's per-id LWW upsert naturally
// dedupes instead of duplicating.
//
// Unlike `backfillTaskEventId` (kind-qualified over a task id), these are
// migration-source-qualified over the DefaultPool/template id — the
// namespace string's `pools-p1:` prefix + literal middle segment is what
// keeps the three mint sites from colliding with each other or with any
// other uuidv5 consumer sharing `OYBC_NAMESPACE`.
//
// ONLY the migration mint sites use these — the legacy-create paths
// (web `wizardPersist.ts`, iOS `BoardWizardPersist.swift`) mint at
// user-action time on a single device and correctly keep random ids; see
// each file's header for why deterministic ids would be wrong there.

/**
 * Deterministic id for the `Pool` minted from a `DefaultPool` row during the
 * P1 migration (docs §Migration, step 1). Keyed off `defaultPool.id` so two
 * devices migrating the same DefaultPool row independently mint the SAME
 * Pool id.
 *
 * @param defaultPoolId The source `DefaultPool.id`.
 * @returns A deterministic v5 UUID.
 */
export function migrationDefaultPoolToPoolId(defaultPoolId: string): string {
  return uuidv5(`pools-p1:defaultPool-pool:${defaultPoolId}`, OYBC_NAMESPACE);
}

/**
 * Deterministic id for the `CoreBoardDefault` minted from a `DefaultPool`
 * row during the P1 migration (docs §Migration, step 1). Keyed off
 * `defaultPool.id` so two devices migrating the same DefaultPool row
 * independently mint the SAME CoreBoardDefault id.
 *
 * @param defaultPoolId The source `DefaultPool.id`.
 * @returns A deterministic v5 UUID.
 */
export function migrationDefaultPoolToCoreBoardDefaultId(defaultPoolId: string): string {
  return uuidv5(`pools-p1:coreBoardDefault:${defaultPoolId}`, OYBC_NAMESPACE);
}

/**
 * Deterministic id for the `Pool` minted from a `RecurringBoardTemplate`'s
 * `seedTaskIds` during the P1 migration (docs §Migration, step 2). Keyed off
 * `template.id` so two devices migrating the same template row independently
 * mint the SAME Pool id.
 *
 * @param templateId The source `RecurringBoardTemplate.id`.
 * @returns A deterministic v5 UUID.
 */
export function migrationTemplateToPoolId(templateId: string): string {
  return uuidv5(`pools-p1:template-pool:${templateId}`, OYBC_NAMESPACE);
}
