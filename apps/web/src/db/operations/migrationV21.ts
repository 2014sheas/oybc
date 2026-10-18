import type { Transaction } from 'dexie';
import { db } from '../internal';
import { runPlacementSweep } from './placementSweep';

/**
 * Dexie v21 data migration — the first-open run of the placement sweep
 * (TASK_WINDOW_REWORK slice 4a). Runs the sweep for every local user row; a
 * failure is logged, never thrown (the upgrade must not block the app open —
 * the sweep re-runs at every open and after every pull).
 *
 * @param _tx The Dexie upgrade transaction (unused; the sweep opens its own).
 */
export async function runMigrationV21(_tx: Transaction): Promise<void> {
  try {
    const users = await db.users.toArray();
    for (const u of users) await runPlacementSweep(u.id);
  } catch (err) {
    console.error('[migrationV21] placement sweep failed', err);
  }
}
