/**
 * Compound-structure editing — the one write path for changing a compound
 * task's rule (operator / threshold) and sub-tasks after creation.
 *
 * Two callers share the same inner body
 * ({@link applyCompoundStructureEditInTransaction}):
 *   - the board wizard's staged-edit apply (`wizardBoard.ts`
 *     `applyStagedTaskEditsForWizardPersist`), inside the wizard's own
 *     persist transaction; and
 *   - the Task Detail edit sheet, which saves immediately through
 *     {@link editCompoundStructure} / {@link saveTaskEdit}.
 *
 * Semantics are identical on both paths: parent fields via
 * `applyPatchToTask` (operator + clamped threshold), sub-task CRUD via
 * {@link applyStagedCompoundChildEdits} (a removed sub-task soft-deletes the
 * LINK only — the child Task survives), one version bump + one sync enqueue
 * for the parent, then ONE batched board cascade covering the parent and
 * every child whose fields actually changed. Sealed boards are skipped by
 * the cascade itself (`runBoardCascadeForTasks`).
 *
 * Import direction: this module imports `updateTaskAndCascade` from
 * `./tasks.crud`; `tasks.crud.ts` must NEVER import this module (circular).
 */
import { SyncOperationType, TaskType, type CompoundChild, type Task } from '@oybc/shared';
import { db } from '../internal';
import { currentTimestamp, generateUUID } from '../utils';
import {
  type TaskEditPatch,
  applyPatchToTask,
  applyStepToChildTask,
  buildNewChildTask,
  isNewChild,
  validatePatch,
} from '../taskEditPatch';
import { runBoardCascadeForTasks } from './orchestration';
import { addToSyncQueue } from './syncQueue';
import { updateTaskAndCascade, type UpdateTaskPatch } from './tasks.crud';

/**
 * Applies a staged compound patch's child edits to its `compound_children`
 * links + child Task rows. Called by {@link applyCompoundStructureEditInTransaction}
 * — for a staged wizard compound edit (library or already-written pending
 * compound) and for the standalone Task Detail save alike.
 * The parent Task itself is saved by the caller AFTER this returns. Web
 * port of iOS `AppDatabase.applyStagedCompoundChildEdits`.
 *
 * Semantics: a kept new sub-task mints a child Task + link; a kept existing
 * sub-task edits its child Task GLOBALLY (reindexing its link to display
 * order); a removed sub-task (deleted or blank-titled) soft-deletes the
 * LINK only — the child Task survives (orphans acceptable). Sub-tasks
 * persist in `patch.children` order.
 *
 * Must run inside an active Dexie transaction covering `tasks` and
 * `compoundChildren` (plus `syncQueue` for the enqueues below).
 *
 * @returns The ids of existing child Tasks whose fields actually changed —
 *   the caller batches these into ONE cascade pass alongside the parent id
 *   (mirrors `orchestration.ts`'s "recompute each affected task's caches
 *   once" guidance) rather than cascading per-child inline.
 */
export async function applyStagedCompoundChildEdits(
  parentId: string,
  parentUserId: string,
  patch: TaskEditPatch,
  now: string,
): Promise<string[]> {
  const existingLinks = (
    await db.compoundChildren.where('compoundTaskId').equals(parentId).toArray()
  ).filter((c) => !c.isDeleted);
  const linkByChildId = new Map(existingLinks.map((l) => [l.childTaskId, l]));

  const keptChildIds = new Set<string>();
  const touchedChildIds: string[] = [];
  let displayIndex = 0;

  for (const step of patch.children) {
    const title = step.title.trim();
    // Removed = explicitly deleted OR blank-titled ("dropped on save").
    if (step.markedDeleted || title.length === 0) continue;
    const index = displayIndex++;

    if (isNewChild(step)) {
      const childId = generateUUID();
      const child = buildNewChildTask(childId, step, title, parentUserId, now);
      await db.tasks.add(child);
      await addToSyncQueue('tasks', childId, SyncOperationType.CREATE, child);
      const link: CompoundChild = {
        id: generateUUID(),
        compoundTaskId: parentId,
        childTaskId: childId,
        childIndex: index,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };
      await db.compoundChildren.add(link);
      await addToSyncQueue('compoundChildren', link.id, SyncOperationType.CREATE, link);
      keptChildIds.add(childId);
    } else if (step.childTaskId) {
      const childId = step.childTaskId;
      keptChildIds.add(childId);
      // Global child edit (rename / goal / unit).
      const existingChild = await db.tasks.get(childId);
      if (existingChild) {
        const updated = applyStepToChildTask(existingChild, step, title);
        const changed =
          updated.title !== existingChild.title ||
          updated.action !== existingChild.action ||
          updated.unit !== existingChild.unit ||
          updated.maxCount !== existingChild.maxCount;
        if (changed) {
          const saved: Task = { ...updated, version: (existingChild.version ?? 1) + 1, updatedAt: now };
          await db.tasks.update(childId, saved);
          await addToSyncQueue('tasks', childId, SyncOperationType.UPDATE, saved);
          touchedChildIds.push(childId);
        }
      }
      // Reindex the link to display order if it moved.
      const link = linkByChildId.get(childId);
      if (link && link.childIndex !== index) {
        const updatedLink: CompoundChild = { ...link, childIndex: index, version: link.version + 1, updatedAt: now };
        await db.compoundChildren.update(link.id, updatedLink);
        await addToSyncQueue('compoundChildren', link.id, SyncOperationType.UPDATE, updatedLink);
      }
    }
  }

  // Soft-delete links whose child is no longer kept (link only — the child
  // Task stays in the library; orphans are acceptable per product decision).
  for (const link of existingLinks) {
    if (keptChildIds.has(link.childTaskId)) continue;
    const updatedLink: CompoundChild = { ...link, isDeleted: true, deletedAt: now, version: link.version + 1, updatedAt: now };
    await db.compoundChildren.update(link.id, updatedLink);
    await addToSyncQueue('compoundChildren', link.id, SyncOperationType.UPDATE, updatedLink);
  }

  return touchedChildIds;
}

/**
 * Basic (non-structural) fields that ride along with a standalone compound
 * save, so the Task Detail sheet's description/time-window edits land in the
 * SAME version bump as the structure change (the title rides in
 * `structure.title`, not here). `null` clears a field
 * (mapped to `undefined`, exactly as `updateTask` maps its `null` sentinels);
 * `undefined` leaves the stored value untouched.
 */
export type CompoundEditBasic = {
  description?: string;
  timeframe?: string | null;
  startDate?: string | null;
  endDate?: string | null;
};

/**
 * Thrown by {@link editCompoundStructure} when the structure patch fails
 * `validatePatch` (e.g. fewer than two sub-tasks). The message is
 * `validatePatch`'s user-facing string; nothing has been written.
 */
export class CompoundEditValidationError extends Error {
  readonly kind = 'validation' as const;

  /** @param message - The `validatePatch` failure message, shown verbatim. */
  constructor(message: string) {
    super(message);
    this.name = 'CompoundEditValidationError';
  }
}

/** The transaction scope `runBoardCascadeForTasks` requires. */
const CASCADE_TABLES = () => [
  db.boards,
  db.boardTasks,
  db.tasks,
  db.compoundChildren,
  db.taskEvents,
  db.syncQueue,
];

/**
 * Inner body of a compound-structure edit: parent fields + sub-task CRUD +
 * version bump + parent enqueue + one batched cascade.
 *
 * REQUIRES an active Dexie transaction over `boards`, `boardTasks`, `tasks`,
 * `compoundChildren`, `taskEvents` and `syncQueue`. Performs no validation —
 * callers validate first (the wizard skips invalid patches silently;
 * {@link editCompoundStructure} throws).
 *
 * @param task - The stored compound Task row (pre-edit).
 * @param structure - The edited title / operator / threshold / sub-tasks.
 * @param basic - Optional basic fields applied in the same version bump.
 * @param now - ISO8601 timestamp for version bumps + sync-queue rows.
 */
export async function applyCompoundStructureEditInTransaction(
  task: Task,
  structure: TaskEditPatch,
  basic: CompoundEditBasic,
  now: string,
): Promise<void> {
  const updated = applyPatchToTask(structure, task);
  const touchedChildIds = await applyStagedCompoundChildEdits(task.id, task.userId, structure, now);
  const saved: Task = {
    ...updated,
    ...(basic.description !== undefined ? { description: basic.description.trim() || undefined } : {}),
    // `null` → `undefined`: the same sentinel mapping `updateTask` applies
    // (and the same `string` → `Timeframe` cast its `as Partial<Task>` makes).
    ...(basic.timeframe !== undefined
      ? { timeframe: (basic.timeframe ?? undefined) as Task['timeframe'] }
      : {}),
    ...(basic.startDate !== undefined ? { startDate: basic.startDate ?? undefined } : {}),
    ...(basic.endDate !== undefined ? { endDate: basic.endDate ?? undefined } : {}),
    version: (task.version ?? 1) + 1,
    updatedAt: now,
  };
  await db.tasks.update(task.id, saved);
  await addToSyncQueue('tasks', task.id, SyncOperationType.UPDATE, saved);
  await runBoardCascadeForTasks([task.id, ...touchedChildIds]);
}

/**
 * Throws unless `task` is a live (not soft-deleted) compound.
 *
 * @param task - The row read for `taskId` (may be undefined).
 * @param taskId - Id used in the error message.
 * @throws Error `Task … not found` / `Task … is not a compound task`.
 */
function assertLiveCompound(task: Task | undefined, taskId: string): asserts task is Task {
  if (!task || task.isDeleted) throw new Error(`Task ${taskId} not found`);
  if (task.type !== TaskType.COMPOUND) throw new Error(`Task ${taskId} is not a compound task`);
}

/**
 * Standalone Task-Detail save for a compound: validates, then applies the
 * structure edit (plus any basic fields) and re-derives every live board the
 * compound — or a changed sub-task — sits on, all in one transaction.
 *
 * @param taskId - The compound Task's id.
 * @param structure - The edited title / operator / threshold / sub-tasks.
 * @param basic - Optional description / time-window fields (same version bump).
 * @throws Error when the task is missing/deleted or is not a compound.
 * @throws CompoundEditValidationError (message = `validatePatch`'s) before
 *   writing anything when the patch is invalid.
 */
export async function editCompoundStructure(
  taskId: string,
  structure: TaskEditPatch,
  basic: CompoundEditBasic = {},
): Promise<void> {
  // Pre-checks run outside any transaction so a validation failure never
  // opens one.
  assertLiveCompound(await db.tasks.get(taskId), taskId);
  const problem = validatePatch(structure, TaskType.COMPOUND);
  if (problem !== null) throw new CompoundEditValidationError(problem);
  const now = currentTimestamp();
  await db.transaction('rw', CASCADE_TABLES(), async () => {
    // Re-read INSIDE the transaction: the full row written below is built
    // from this read, so a sync pull / other-tab write that landed after the
    // pre-read is preserved (and the version bumps from it) instead of being
    // overwritten with stale fields. A throw here aborts with no writes.
    const fresh = await db.tasks.get(taskId);
    assertLiveCompound(fresh, taskId);
    await applyCompoundStructureEditInTransaction(fresh, structure, basic, now);
  });
}

/**
 * What the Task Detail edit sheet submits: the ordinary `UpdateTaskPatch`,
 * plus — for a compound whose structure the user edited — the structure
 * patch.
 */
export type TaskEditSubmit = UpdateTaskPatch & { compound?: TaskEditPatch };

/**
 * Router used by both Task Detail edit call sites. A submit carrying
 * `compound` goes through {@link editCompoundStructure} (basic fields ride
 * along in the same version bump); anything else goes through
 * `updateTaskAndCascade` unchanged.
 *
 * @param taskId - The task being edited.
 * @param submit - The sheet's submit payload.
 * @throws CompoundEditValidationError for an invalid compound structure;
 *   otherwise whatever `updateTaskAndCascade` / `editCompoundStructure` throw.
 */
export async function saveTaskEdit(taskId: string, submit: TaskEditSubmit): Promise<void> {
  const { compound, ...basicPatch } = submit;
  if (compound) {
    const { timeframe, startDate, endDate } = basicPatch;
    // The sheet sends `description: undefined` to CLEAR a description (Dexie
    // deletes a key whose update value is `undefined`, which is how
    // `updateTask` clears it). `CompoundEditBasic` reads `undefined` as
    // "untouched", so a present-but-undefined key becomes '' (→ cleared) to
    // keep both routes agreeing; an absent key stays untouched.
    const description = 'description' in basicPatch ? (basicPatch.description ?? '') : undefined;
    await editCompoundStructure(taskId, compound, { description, timeframe, startDate, endDate });
    return;
  }
  await updateTaskAndCascade(taskId, basicPatch);
}
