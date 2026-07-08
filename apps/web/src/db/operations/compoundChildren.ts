/**
 * CRUD operations for the compoundChildren collection.
 *
 * All writes go to Dexie first (local source of truth), then enqueue a sync
 * entry so the background SyncService can propagate changes to Firestore.
 */

import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { SyncOperationType } from '@oybc/shared';
import type { CompoundChild, CreateCompoundChildInput } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

// ─── Read Operations ──────────────────────────────────────────────────────────

/**
 * Fetch all non-deleted compound children for a parent compound, ordered by
 * childIndex.
 *
 * @param compoundTaskId - The parent compound task id.
 * @returns Ordered array of non-deleted CompoundChild rows.
 */
export async function fetchCompoundChildren(compoundTaskId: string): Promise<CompoundChild[]> {
  const rows = await db.compoundChildren
    .where('compoundTaskId')
    .equals(compoundTaskId)
    .filter((c) => !c.isDeleted)
    .sortBy('childIndex');
  return rows;
}

/**
 * Fetch every non-deleted compound_children row in the workspace, used by the
 * derivation pass to find transitive parent compounds.
 *
 * Caller can also use this to build the `childrenByCompound` map fed into
 * `computeBoardStatsUpdate` from `@oybc/shared`. Small-N: typical user has
 * fewer than a few hundred compound child links.
 *
 * @returns All non-deleted CompoundChild rows across all compounds.
 */
export async function fetchAllCompoundChildren(): Promise<CompoundChild[]> {
  return db.compoundChildren.filter((c) => !c.isDeleted).toArray();
}

/**
 * Fetch non-deleted compound_children links for a set of parent compound ids.
 *
 * Uses the `compoundTaskId` index (so Dexie hits only matching rows) then
 * filters `!isDeleted` in memory. Used by the wizard's "From a board" grid
 * to preview compound leaves for the boards it renders.
 *
 * @param compoundIds - Parent compound task ids to look up.
 * @returns Non-deleted CompoundChild rows for those compounds (unsorted).
 */
export async function fetchCompoundChildrenByCompoundIds(
  compoundIds: string[],
): Promise<CompoundChild[]> {
  const matching = await db.compoundChildren
    .where('compoundTaskId')
    .anyOf(compoundIds)
    .toArray();
  return matching.filter((c) => !c.isDeleted);
}

/**
 * Fetch one compound child by id.
 *
 * @param id - The compound child row id.
 * @returns The CompoundChild row, or undefined if not found.
 */
export async function fetchCompoundChild(id: string): Promise<CompoundChild | undefined> {
  return db.compoundChildren.get(id);
}

// ─── Write Operations ─────────────────────────────────────────────────────────

/**
 * Create a new compound_children row.
 *
 * Caller is responsible for ensuring `childTaskId` exists in `tasks` and
 * doesn't equal `compoundTaskId` (Zod already enforces self-reference but
 * an upstream FK check is the caller's job). Enqueues a CREATE sync entry.
 *
 * @param input - Fields required to create the compound child link.
 * @returns The newly created CompoundChild row.
 */
export async function createCompoundChild(input: CreateCompoundChildInput): Promise<CompoundChild> {
  const row: CompoundChild = {
    id: generateUUID(),
    compoundTaskId: input.compoundTaskId,
    childTaskId: input.childTaskId,
    childIndex: input.childIndex,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };
  await db.compoundChildren.add(row);
  await addToSyncQueue('compoundChildren', row.id, SyncOperationType.CREATE, row);
  return row;
}

/**
 * Soft-delete a compound child. Bumps version + updatedAt; enqueues UPDATE sync.
 *
 * The derivation pass reads non-deleted children only, so a soft-delete makes
 * the parent compound recompute as if the child was removed.
 *
 * @param id - The compound child row id to soft-delete.
 */
export async function softDeleteCompoundChild(id: string): Promise<void> {
  const existing = await db.compoundChildren.get(id);
  if (!existing || existing.isDeleted) return;
  const update: Partial<CompoundChild> = {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: existing.version + 1,
  };
  await db.compoundChildren.update(id, update);
  await addToSyncQueue('compoundChildren', id, SyncOperationType.UPDATE, { ...existing, ...update });
}

/**
 * Reorder a compound's children to match `orderedChildIds`. Updates each row's
 * `childIndex` to its position in the array. Each modified row gets version++,
 * updatedAt bumped, and an UPDATE sync entry. Rows whose position is unchanged
 * are skipped.
 *
 * Wrapped in a single Dexie transaction for atomicity.
 *
 * @param compoundTaskId - The parent compound task id (used as a guard: rows
 *   belonging to a different parent are silently skipped).
 * @param orderedChildIds - Child row ids in the desired order. Index in the
 *   array becomes the new `childIndex`.
 */
export async function reorderCompoundChildren(
  compoundTaskId: string,
  orderedChildIds: string[],
): Promise<void> {
  await db.transaction('rw', [db.compoundChildren, db.syncQueue], async () => {
    for (let i = 0; i < orderedChildIds.length; i++) {
      const id = orderedChildIds[i];
      const existing = await db.compoundChildren.get(id);
      if (!existing) continue;
      if (existing.compoundTaskId !== compoundTaskId) continue;
      if (existing.childIndex === i) continue;
      const update: Partial<CompoundChild> = {
        childIndex: i,
        updatedAt: currentTimestamp(),
        version: existing.version + 1,
      };
      await db.compoundChildren.update(id, update);
      await addToSyncQueue('compoundChildren', id, SyncOperationType.UPDATE, {
        ...existing,
        ...update,
      });
    }
  });
}

/**
 * Find every parent compound that lists this `childTaskId` as a child.
 * Used when soft-deleting a Task: the caller should cascade by soft-deleting
 * matching compound_children rows so parent compounds recompute.
 *
 * @param childTaskId - The task id to look up as a child.
 * @returns All non-deleted CompoundChild rows where childTaskId matches.
 */
export async function findCompoundChildrenByChildTaskId(
  childTaskId: string,
): Promise<CompoundChild[]> {
  return db.compoundChildren
    .where('childTaskId')
    .equals(childTaskId)
    .filter((c) => !c.isDeleted)
    .toArray();
}
