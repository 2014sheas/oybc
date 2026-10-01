import type { Transaction } from 'dexie';
import { db } from '../internal';
import { healLinkedCounterWindows } from './linkedCounterWindowHeal';

/**
 * Dexie v18 data migration — windowed linked counters (owner rule
 * 2026-10-01: a counting square on a board accounts ONLY for the counter's
 * logs inside that board's window).
 *
 * Runs inside the v18 upgrade callback, AFTER v18's `.stores({})` no-op
 * schema declaration (no shape change: the heal adds no fields, it SETS
 * `timeframe`/`startDate`/`endDate`/`createdInWizard` on existing tasks and
 * mints per-board rows through the existing schema). Converts every
 * hub-linked counter (`sharedCounterId` set, no window stamp) that is placed
 * on a board into a window-stamped per-board row — see
 * {@link healLinkedCounterWindows} for the full rules.
 *
 * Scoped per user: runs the heal once for every user id present in
 * `db.users` (a device normally holds one, but a guest→account switch can
 * leave two; the heal's own userId filter keeps their data apart).
 *
 * Idempotent (state-based, no completion marker — same as
 * `migrationV13`/`V14`/`V16`/`V17`): a second run plans nothing. Unlike the
 * v17 backfill this one IS authored — version bumps + sync enqueues — with
 * deterministic content, so peers that heal independently converge; the
 * post-pull sweep in `syncService.ts` re-runs it for data that arrives later
 * (a fresh install pulling pre-rule rows).
 *
 * A heal that throws is caught + logged per user (never rejects the upgrade).
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds
 *            all `db` table ops to the active transaction inside the
 *            callback, same convention as `migrationV16`/`V17`). The heal
 *            opens a nested `rw` transaction, which Dexie joins.
 */
export async function runMigrationV18(_tx: Transaction): Promise<void> {
  const users = await db.users.toArray();
  for (const user of users) {
    // A failed heal must NEVER brick DB open: swallow + log, and let the
    // post-pull sweep in `syncService.ts` retry (the heal is idempotent).
    try {
      await healLinkedCounterWindows(user.id);
    } catch (err) {
      console.warn('[migrationV18] linked-counter window heal failed; the post-pull sweep will retry', err);
    }
  }
}
