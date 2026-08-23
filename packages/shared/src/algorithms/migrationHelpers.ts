import type { Task } from '../types/task';
import type { TaskEvent, TaskEventKind } from '../types/taskEvent';
import { TaskType } from '../constants/enums';
import { isEventOwningTask } from './taskEvents';
import { uuidv5, OYBC_NAMESPACE } from './uuidv5';

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
    if (!task.isCompleted) return null;
    // Best-effort anchor (heal-on-pull, docs §Heal-on-pull): a completed task
    // should never be lost for lack of a `completedAt`. Prefer `completedAt`
    // (exact-window placement); fall back to `updatedAt`, then `createdAt`
    // (both always present) so a legacy `isCompleted`-without-`completedAt` row
    // still mints an event instead of being dropped.
    const occurredAt = task.completedAt ?? task.updatedAt ?? task.createdAt;
    return {
      ...base,
      id: backfillTaskEventId(task.id, 'completion'),
      kind: 'completion',
      occurredAt,
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
    occurredAt: task.completedAt ?? task.updatedAt ?? task.createdAt,
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
