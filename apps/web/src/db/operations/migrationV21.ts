import type { Transaction } from 'dexie';

/**
 * Dexie v21 data migration — was the first-open run of the placement sweep
 * (TASK_WINDOW_REWORK slice 4a). The sweep was retired in slice 5 once every
 * stamped row had been converted; the version stays registered as a no-op
 * (migration history is never removed).
 *
 * @param _tx The Dexie upgrade transaction (unused).
 */
export async function runMigrationV21(_tx: Transaction): Promise<void> {}
