import type { Transaction } from 'dexie';
import { db } from '../internal';

/**
 * Dexie v17 data migration — Board-integrity PR-1
 * (docs/BOARD_INTEGRITY.md) — `BoardTask` gains `isDeleted`/`deletedAt`,
 * mirroring every other synced collection.
 *
 * Runs inside the v17 upgrade callback (one atomic transaction), AFTER v17's
 * `.stores({})` no-op schema declaration. `BoardTask` was previously the
 * ONLY synced collection without a soft-delete flag: placement removal was
 * a physical Dexie delete, and the sync layer represented "delete" purely
 * as a pushed doc with no tombstone marker. A delete on an already-synced
 * row therefore LOST the LWW tie-break against the still-live remote copy
 * (same version, same `updatedAt` — an exact tie resolves to remote per
 * `resolveConflict`) and self-reverted within one safety-net pull cycle.
 * `isDeleted`/`deletedAt` let a delete carry a version bump that actually
 * wins the tie-break.
 *
 * Backfills `isDeleted: false` on every existing `boardTasks` row that
 * doesn't already have the field set. Idempotent: a second run sees every
 * row already carrying an explicit `isDeleted` value and does nothing
 * (mirrors the state-based idempotency pattern used by
 * `migrationV13`/`migrationV14`/`migrationV16` — no separate "migration
 * completed" marker table).
 *
 * Purely local — no version bump / sync enqueue on the backfilled rows.
 * Every pre-v17 remote doc (this device's own past pushes, and every
 * peer's) already implicitly means "not deleted" by omission; the Zod
 * schema's `isDeleted: z.boolean().default(false)` decodes an absent
 * remote field the same way. Backfilling to an explicit `false` here only
 * satisfies the TS `BoardTask.isDeleted: boolean` (non-optional) contract
 * for in-memory reads — it changes no semantics either device agrees on,
 * so there is nothing new to converge.
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds
 *            all `db` table ops to the active transaction inside the
 *            callback, same convention as `migrationV16`).
 */
export async function runMigrationV17(_tx: Transaction): Promise<void> {
  const allBoardTasks = await db.boardTasks.toArray();
  for (const bt of allBoardTasks) {
    if ((bt as { isDeleted?: boolean }).isDeleted !== undefined) continue;
    await db.boardTasks.update(bt.id, { isDeleted: false });
  }
}
