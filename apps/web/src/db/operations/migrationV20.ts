import type { Transaction } from 'dexie';

/**
 * Dexie v20 data migration — retired no-op (heal retired, TASK_WINDOW_REWORK
 * slice 3a; the slice-4 sweep repoints stamped rows). Kept registered at its version.
 *
 * @param _tx The Dexie upgrade transaction (unused).
 */
export async function runMigrationV20(_tx: Transaction): Promise<void> {
  // heal retired, TASK_WINDOW_REWORK slice 3a; the slice-4 sweep repoints stamped rows
}
