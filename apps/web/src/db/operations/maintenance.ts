import { db } from '../internal';

/**
 * Maintenance / dev-tooling operations.
 *
 * These are not part of the normal offline-first write path; they exist so
 * dev surfaces (the Playground) don't reach the raw Dexie instance directly.
 */

/**
 * Clear every table in the local database.
 *
 * ⚠️ Destructive — wipes all local data (boards, tasks, sync queue, …) in a
 * single transaction. Only the dev Playground's "Clear Test Data" control
 * calls this. Does NOT touch Firestore; a subsequent sync pull would
 * re-hydrate from the server if signed in.
 */
export async function clearAllTables(): Promise<void> {
  await db.transaction('rw', db.tables, async () => {
    await Promise.all(db.tables.map((table) => table.clear()));
  });
}
