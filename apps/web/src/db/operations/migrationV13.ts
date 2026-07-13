import type { Transaction } from 'dexie';
import { db } from '../internal';
import type { Task, TaskEvent } from '@oybc/shared';
import { SyncOperationType, SyncStatus, buildBackfillTaskEvent } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Dexie v13 data migration — Windowed Completion event backfill
 * (docs/WINDOWED_COMPLETION.md §Migration & backfill, step 2).
 *
 * Runs inside the v13 upgrade callback, so every write here is part of one
 * atomic transaction. v12 (PR B sub-slice 1) created the `taskEvents` store
 * empty; this migration synthesizes the DETERMINISTIC backfill events from
 * existing lifetime task state so a task placed on a live board that contains
 * its `completedAt` keeps its green (bleed preserved once), while later windows
 * start empty.
 *
 * Only step 2 of the doc's migration is B's responsibility. Step 3 (sealing
 * expired boards) is assigned to PR C by the phasing table ("migration
 * sealing" lives in the C row), so this migration does NOT seal anything.
 * Step 4 (cache restamp) is a no-op — the events are DERIVED FROM the caches,
 * so they're already consistent by construction.
 *
 * Per the carve-out (doc §Derived-task carve-out rule 2), `buildBackfillTaskEvent`
 * returns `null` for derived / compound / achievement tasks, so they are
 * skipped entirely — minting an event from a derived counter's mirrored
 * `currentCount` would double-count the source's history.
 *
 * Determinism: `buildBackfillTaskEvent` assigns a kind-qualified `uuidv5` id and
 * takes timestamps from the task snapshot (not migration wall-clock), so two
 * devices mint the same-id row and LWW picks the one derived from the fresher
 * task state — order of migration is irrelevant. Backfilled events are enqueued
 * for sync CREATE (they MUST reach Firestore or another device's pull recompute
 * would zero the caches).
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds all
 *            `db` table ops to the active transaction inside the callback).
 */
export async function runMigrationV13(_tx: Transaction): Promise<void> {
  const allTasks: Task[] = await db.tasks.toArray();

  for (const task of allTasks) {
    const event: TaskEvent | null = buildBackfillTaskEvent(task);
    if (!event) continue; // deleted / non-event-owning / nothing to backfill

    // Idempotency belt: the deterministic id means a re-run (or a peer's
    // already-synced row) would collide. Skip if the row already exists.
    const existing = await db.taskEvents.get(event.id);
    if (existing) continue;

    await db.taskEvents.add(event);

    // Enqueue sync CREATE directly (NOT addToSyncQueue — that helper opens its
    // own transaction and isn't upgrade-tx-aware, matching migrationV4).
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'taskEvents',
      entityId: event.id,
      operationType: SyncOperationType.CREATE,
      payload: JSON.stringify(event),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  }
}
