/**
 * CRUD operations for the compoundChildren collection.
 *
 * All writes go to Dexie first (local source of truth), then enqueue a sync
 * entry so the background SyncService can propagate changes to Firestore.
 *
 * ⚠️ MUTATOR CAVEAT (pre-WC audit, issue #379): `createCompoundChild` has NO
 * production callers today (compound authoring is create-only via
 * `createCompound`) and does not run the board derivation cascade. Restructuring a compound's
 * children changes every placed parent's windowed completion — a future
 * compound-editing UI that reuses these MUST follow each write with
 * `runBoardCascadeForTask(parentCompoundId, ...)` (orchestration.ts) or the
 * affected boards' stats/bingo lines go stale until the next self-heal.
 */

import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { SyncOperationType, isGoalLessCounter } from '@oybc/shared';
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
 * filters `!isDeleted` in memory. Used by the Board Sources member-rules
 * resolution (docs/BOARD_SOURCES.md §Member rules — Plan B); no caller
 * until B lands.
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

// ─── Write Operations ─────────────────────────────────────────────────────────

/**
 * Create a new compound_children row.
 *
 * Caller is responsible for ensuring `childTaskId` exists in `tasks` and
 * doesn't equal `compoundTaskId` (Zod already enforces self-reference but
 * an upstream FK check is the caller's job). Enqueues a CREATE sync entry.
 *
 * P5 guard: rejects a goal-less counter (`isGoalLessCounter`) as a child —
 * a hub-born counter with no `maxCount` has nothing evaluable to
 * contribute to a compound's AND/OR/M_OF_N logic (docs/SHARED_COUNTERS.md
 * §P5). A promoted counter (still `isCounter` but with a `maxCount`) is
 * unaffected and may be a child normally.
 *
 * @param input - Fields required to create the compound child link.
 * @returns The newly created CompoundChild row.
 * @throws If the referenced child task is a goal-less counter.
 */
export async function createCompoundChild(input: CreateCompoundChildInput): Promise<CompoundChild> {
  const child = await db.tasks.get(input.childTaskId);
  if (child && isGoalLessCounter(child)) {
    throw new Error('createCompoundChild: goal-less counter tasks cannot be compound children');
  }
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
