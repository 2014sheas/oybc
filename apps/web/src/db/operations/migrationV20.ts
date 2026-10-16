import type { Transaction } from 'dexie';
import { db } from '../internal';
import { healLinkedCounterWindows } from './linkedCounterWindowHeal';

/**
 * Dexie v20 data migration — re-run the windowed-linked-counter heal once
 * (2026-10-16): the v18 heal stamped a linked counting row that a compound
 * carried ("reached-only single board → stamp"), and a daily series that
 * re-places the same compound every window then read that child over its
 * FIRST day everywhere (0 of 10 after a 26-mile log) and froze it out of
 * propagation. The planner now never stamps a compound member and plans an
 * un-stamp for one an earlier heal pinned — see {@link healLinkedCounterWindows}.
 *
 * Same shape as `migrationV18`: no schema change (`.stores({})` no-op), one
 * idempotent authored heal per user id in `db.users`, a throw caught + logged
 * per user (never rejects the upgrade); the post-pull sweep in
 * `syncService.ts` re-runs the same heal for rows that arrive later.
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds
 *            all `db` table ops to the active transaction inside the
 *            callback). The heal opens a nested `rw` transaction, which
 *            Dexie joins.
 */
export async function runMigrationV20(_tx: Transaction): Promise<void> {
  const users = await db.users.toArray();
  for (const user of users) {
    try {
      await healLinkedCounterWindows(user.id);
    } catch (err) {
      console.warn('[migrationV20] linked-counter window heal failed; the post-pull sweep will retry', err);
    }
  }
}
