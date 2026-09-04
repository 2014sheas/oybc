import { db } from '../internal';
import type {
  RecurringBoardTemplate,
  CreateRecurringBoardTemplateInput,
  UpdateRecurringBoardTemplateInput,
} from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * RecurringBoardTemplate CRUD operations (Phase 6.2).
 *
 * Each write enqueues a `syncQueue` entry inline (mirror of `boards.ts`).
 * The spawn path lives in `recurringBoardSpawn.ts` because it composes
 * multiple writes inside a single Dexie transaction; the helpers here
 * are single-row CRUD.
 */

/**
 * Fetch all non-deleted templates for a user, sorted by `updatedAt desc`.
 */
export async function fetchRecurringBoardTemplates(
  userId: string,
): Promise<RecurringBoardTemplate[]> {
  return db.recurringBoardTemplates
    .filter((t) => t.userId === userId && !t.isDeleted)
    .reverse()
    .sortBy('updatedAt');
}

/**
 * Fetch every non-deleted template across all users, sorted by name.
 *
 * Used by the Achievement template picker, which lists all templates (not
 * user-scoped) in name order.
 *
 * @returns All non-deleted RecurringBoardTemplate rows, sorted by `name`.
 */
export async function fetchAllTemplatesSortedByName(): Promise<
  RecurringBoardTemplate[]
> {
  return db.recurringBoardTemplates.filter((t) => !t.isDeleted).sortBy('name');
}

/**
 * Fetch a single template by id.
 */
export async function fetchRecurringBoardTemplate(
  id: string,
): Promise<RecurringBoardTemplate | undefined> {
  return db.recurringBoardTemplates.get(id);
}

/**
 * Create a new template. `lastSpawnedWindowKey` starts as `null` — the next
 * Boards-tab open will trigger a spawn for the current window.
 */
export async function createRecurringBoardTemplate(
  userId: string,
  input: CreateRecurringBoardTemplateInput,
): Promise<RecurringBoardTemplate> {
  const now = currentTimestamp();
  const template: RecurringBoardTemplate = {
    id: generateUUID(),
    userId,
    name: input.name.trim(),
    timeframe: input.timeframe,
    boardSize: input.boardSize,
    centerSquareType: input.centerSquareType,
    isRandomized: input.isRandomized,
    seedTaskIds: [...input.seedTaskIds],
    lastSpawnedWindowKey: null,
    isActive: input.isActive,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };
  // P1 — additive, optional. The legacy template CREATE write-through
  // (`wizardPersist.ts persistRecurringTemplate`) mints a Pool and passes
  // these so the record is born already-migrated-shaped; callers that omit
  // them (pre-P1 tests, any future un-migrated path) get the "genuinely
  // un-migrated" shape (fields absent), same as `isLegacyShapedRecord`'s
  // docstring describes.
  if (input.poolIds !== undefined) template.poolIds = [...input.poolIds];
  if (input.manualTaskIds !== undefined) template.manualTaskIds = [...input.manualTaskIds];
  if (input.removedTaskIds !== undefined) template.removedTaskIds = [...input.removedTaskIds];
  // Board Sources P1 — canonical sources stamp (docs/BOARD_SOURCES.md).
  if (input.sources !== undefined) {
    template.sources = input.sources.map((s) => ({
      ...s,
      excludedTaskIds: [...s.excludedTaskIds],
    }));
  }

  await db.recurringBoardTemplates.add(template);
  await addToSyncQueue(
    'recurringBoardTemplates',
    template.id,
    SyncOperationType.CREATE,
    template,
  );
  return template;
}

/**
 * Update a template. Bumps `version` + `updatedAt`. Excludes
 * `lastSpawnedWindowKey` — that's mutated only by the spawn path.
 */
export async function updateRecurringBoardTemplate(
  id: string,
  updates: UpdateRecurringBoardTemplateInput,
): Promise<void> {
  const existing = await db.recurringBoardTemplates.get(id);
  if (!existing) return;

  const patch: Partial<RecurringBoardTemplate> = {
    ...updates,
    name: updates.name !== undefined ? updates.name.trim() : undefined,
    seedTaskIds: updates.seedTaskIds ? [...updates.seedTaskIds] : undefined,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  // Remove `undefined` keys so Dexie doesn't overwrite existing values
  // with undefined (a Dexie .update quirk).
  for (const key of Object.keys(patch) as (keyof typeof patch)[]) {
    if (patch[key] === undefined) delete patch[key];
  }

  await db.recurringBoardTemplates.update(id, patch);
  const updated = await db.recurringBoardTemplates.get(id);
  if (updated) {
    await addToSyncQueue(
      'recurringBoardTemplates',
      id,
      SyncOperationType.UPDATE,
      updated,
    );
  }
}

/**
 * Soft-delete a template. Spawned boards remain — they're independent
 * once spawned (locked decision). Bumps `version` so LWW treats the
 * deletion as later-wins.
 */
export async function softDeleteRecurringBoardTemplate(id: string): Promise<void> {
  const existing = await db.recurringBoardTemplates.get(id);
  if (!existing) return;

  await db.recurringBoardTemplates.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });

  const tombstone = await db.recurringBoardTemplates.get(id);
  if (tombstone) {
    await addToSyncQueue(
      'recurringBoardTemplates',
      id,
      SyncOperationType.DELETE,
      tombstone,
    );
  }
}

/**
 * Fetch all non-deleted recurring board templates that include the given
 * task ID in their `seedTaskIds` pool.
 *
 * Soft-deleted tasks are intentionally retained in `seedTaskIds` per the
 * schema (the template itself may still be active). This query therefore
 * filters only on template `isDeleted`, not on the task's state.
 *
 * @param taskId - ID of the task to scan for
 * @returns templates whose seedTaskIds contains taskId
 */
export async function fetchTemplatesReferencingTask(
  taskId: string,
): Promise<RecurringBoardTemplate[]> {
  return db.recurringBoardTemplates
    .filter((t) => !t.isDeleted && Array.isArray(t.seedTaskIds) && t.seedTaskIds.includes(taskId))
    .toArray();
}

