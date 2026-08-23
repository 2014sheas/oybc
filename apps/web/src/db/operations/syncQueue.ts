import { db } from '../internal';
import type { SyncQueueItem } from '@oybc/shared';
import {
  MAX_SYNC_RETRIES,
  SyncOperationType,
  SyncStatus,
  isFailedItemEligibleForRetry,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * SyncQueue Operations
 */

/**
 * The outcome of coalescing an incoming enqueue against an existing PENDING
 * row for the same `(entityType, entityId)` pair.
 *
 * - `replace`: keep the existing row's queue position, but set its operation
 *   type to `operationType` and refresh its payload to the incoming snapshot.
 * - `drop`: discard the existing pending row entirely (a create that never
 *   reached the server is now deleted — nothing ever needs to sync).
 */
export type CoalesceResult =
  | { kind: 'replace'; operationType: SyncOperationType }
  | { kind: 'drop' };

/**
 * The queue `entityType` for Windowed Completion task events
 * (docs/WINDOWED_COMPLETION.md §Sync) — the Firestore subcollection name, same
 * value the push path uses for `doc(firestore, 'users', uid, entityType, id)`.
 * Its coalescing precedence is append-only (see {@link coalesceSyncOperation}).
 */
export const TASK_EVENTS_ENTITY_TYPE = 'taskEvents';

/**
 * D3 (issue #296) precedence — decide how an incoming sync op coalesces with
 * an existing PENDING op for the *same entity*. Pure, so both the enqueue
 * path and the unit tests can call it.
 *
 * Precedence table (rows = existing PENDING op, cols = incoming op):
 *
 * ```
 *              incoming CREATE   incoming UPDATE   incoming DELETE
 * CREATE       CREATE            CREATE            DROP* / DELETE
 * UPDATE       CREATE            UPDATE            DELETE
 * DELETE       CREATE (resurr.)  UPDATE (resurr.)  DELETE
 * ```
 * *DROP only when the existing row was never attempted
 * (`existingNeverAttempted`); otherwise DELETE.
 *
 * Reasoning:
 * - **CREATE + UPDATE → CREATE**: the entity hasn't reached the server yet, so
 *   it must still arrive as a create-equivalent. (The push path treats CREATE
 *   and UPDATE identically — both `setDoc(..., { merge: true })` after the same
 *   version conflict-check — so the operation type here is cosmetic; keeping
 *   CREATE just preserves the semantic "not yet on server".)
 * - **CREATE + DELETE → DROP only if never attempted, else DELETE**: dropping
 *   is safe only when the server provably never saw the entity. PENDING alone
 *   doesn't prove that — a push whose `setDoc` landed but whose completion
 *   write failed (or a force-quit mid-push) leaves the row FAILED/IN_PROGRESS
 *   and it is re-promoted/reset back to PENDING with the doc already on the
 *   server; dropping the DELETE then would orphan a live remote doc forever.
 *   Both platforms stamp `lastAttemptAt` when claiming an item for push, so
 *   `existingNeverAttempted` (`lastAttemptAt` unset) proves no push was ever
 *   attempted → ids are client-generated UUIDs, no other device knows the
 *   entity, create-then-delete nets to nothing anywhere → DROP. Otherwise keep
 *   the row as DELETE — pushing a tombstone for a doc that may not exist is
 *   harmless (it just writes an inert `isDeleted=true` doc), whereas an
 *   orphaned live doc is silent divergence. (Board-integrity PR-1,
 *   docs/BOARD_INTEGRITY.md: this was NOT true for `boardTasks` before —
 *   `BoardTask` had no `isDeleted` field, so a DELETE-coalesced payload was
 *   a plain live-looking snapshot with no tombstone marker at all, and the
 *   sync layer never called Firestore `deleteDoc` either. `boardTasks` now
 *   carries `isDeleted`/`deletedAt` like every other collection here, so
 *   this reasoning applies to it uniformly too.)
 * - **UPDATE + DELETE → DELETE**: a standalone PENDING update means the create
 *   already pushed (the server has the doc), so the tombstone (a full snapshot
 *   with `isDeleted=true`) must be pushed to mark it deleted.
 * - **DELETE + CREATE/UPDATE → new op (resurrection)**: the un-pushed tombstone
 *   is stale — the latest local snapshot (isDeleted=false, higher version) is
 *   the truth. Pushing that one full snapshot under LWW yields the correct
 *   server state in a single write, with no ordering dependency (strictly
 *   better than appending a separate DELETE-then-CREATE pair).
 */
export function coalesceSyncOperation(
  existing: SyncOperationType,
  incoming: SyncOperationType,
  existingNeverAttempted: boolean,
  entityType: string
): CoalesceResult {
  // Windowed Completion task events are append-only occurrence rows
  // (docs/WINDOWED_COMPLETION.md §Sync). Two DISTINCT events have distinct ids,
  // so they never meet in the coalescer (it keys on entityId) — that
  // distinctness IS the append-only guarantee: no event is ever collapsed away
  // by another. The coalescer only fires for the SAME event id, whose only real
  // sequence is create → tombstone (undo). Precedence:
  //
  //   - A tombstone SUPERSEDES a pending create — but is NEVER dropped. Backfill
  //     event ids are deterministic (uuidv5), so a peer may already hold the
  //     same id as a live row; only a pushed tombstone converges the undo.
  //     Dropping (as the generic create+delete path does) would strand the undo
  //     locally while the peer's copy stays live → silent divergence.
  //   - Undo is final for an id (a redo is a NEW id), so a tombstone is never
  //     resurrected by a later create/update.
  //   - Any other same-id op stays a create (the event is not yet on the server).
  if (entityType === TASK_EVENTS_ENTITY_TYPE) {
    if (incoming === SyncOperationType.DELETE || existing === SyncOperationType.DELETE) {
      return { kind: 'replace', operationType: SyncOperationType.DELETE };
    }
    return { kind: 'replace', operationType: SyncOperationType.CREATE };
  }

  if (incoming === SyncOperationType.DELETE) {
    return existing === SyncOperationType.CREATE && existingNeverAttempted
      ? { kind: 'drop' }
      : { kind: 'replace', operationType: SyncOperationType.DELETE };
  }
  if (existing === SyncOperationType.DELETE) {
    // Resurrection: the incoming create/update supersedes the un-pushed
    // tombstone.
    return { kind: 'replace', operationType: incoming };
  }
  return {
    kind: 'replace',
    operationType:
      existing === SyncOperationType.CREATE
        ? SyncOperationType.CREATE
        : incoming,
  };
}

/**
 * Add item to sync queue, coalescing per entity.
 *
 * D3 (issue #296): N edits to one entity used to enqueue N full-snapshot rows
 * → N Firestore writes. Instead, if a PENDING row already exists for the same
 * `(entityType, entityId)` we REPLACE its payload + operation type (per
 * {@link coalesceSyncOperation}) in place, keeping the original row's queue
 * position, rather than appending a second snapshot. So an edit burst collapses
 * to a single pending row carrying the LAST snapshot.
 *
 * Position-keeping: replacing preserves the original row's `createdAt` (queue
 * position). That's correct under full-snapshot + LWW sync — conflict
 * resolution is by the entity's `version`, not queue order, and Firestore docs
 * carry no cross-doc referential constraints, so a coalesced row's position
 * relative to *other* entities' rows is immaterial.
 *
 * IN_PROGRESS / FAILED rows are never coalesced into: an IN_PROGRESS row is
 * mid-flight (its snapshot is being pushed), and a FAILED row belongs to the
 * retry/backoff machinery — coalescing into either would corrupt in-flight or
 * bookkeeping state. When the only existing row for the entity is
 * IN_PROGRESS/FAILED we append a fresh PENDING row (which itself coalesces with
 * subsequent edits). When the FAILED row later retries, LWW absorbs any stale
 * snapshot ordering.
 *
 * The lookup + replace/insert runs in its own `db.transaction('rw', syncQueue)`
 * so it is atomic regardless of the caller. When the caller already has an
 * ambient Dexie transaction covering `syncQueue` (post-B4 most enqueues do),
 * Dexie nests this as a sub-transaction — the coalescing stays atomic with the
 * entity write it accompanies; for un-wrapped callers it is still self-atomic
 * (no interleaving between the PENDING lookup and the write).
 */
export async function addToSyncQueue(
  entityType: string,
  entityId: string,
  operationType: SyncOperationType,
  payload: unknown,
  priority: number = 0
): Promise<void> {
  // Skip sync queue for playground data — prevents cross-user pollution.
  // Gated behind DEV so a production build can never silently swallow a
  // legitimate sync because a user happens to match the sentinel string.
  if (import.meta.env.DEV) {
    const payloadObj = payload as Record<string, unknown> | null;
    if (payloadObj?.userId === 'playground-user-1') return;
  }

  await db.transaction('rw', [db.syncQueue], async () => {
    // Coalesce against an existing PENDING row for the same entity. There is
    // at most one post-coalescing; if legacy duplicates exist we target the
    // earliest (by createdAt) to preserve queue position.
    const existingPending = (
      await db.syncQueue
        .where('[entityType+entityId]')
        .equals([entityType, entityId])
        .toArray()
    )
      .filter((row) => row.status === SyncStatus.PENDING)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt))[0];

    if (existingPending) {
      const result = coalesceSyncOperation(
        existingPending.operationType,
        operationType,
        existingPending.lastAttemptAt == null,
        entityType
      );
      if (result.kind === 'drop') {
        await db.syncQueue.delete(existingPending.id);
        return;
      }
      // NOTE: lastAttemptAt is deliberately PRESERVED (not reset) — it is
      // the evidence that a push was attempted for this row (its setDoc may
      // have landed), which the create+delete drop-vs-tombstone decision
      // depends on. Clearing it would let a later delete wrongly drop a
      // create whose doc already reached the server.
      await db.syncQueue.update(existingPending.id, {
        operationType: result.operationType,
        payload: JSON.stringify(payload),
        priority,
        status: SyncStatus.PENDING,
        retryCount: 0,
        lastError: undefined,
      });
      return;
    }

    const item: SyncQueueItem = {
      id: generateUUID(),
      entityType,
      entityId,
      operationType,
      payload: JSON.stringify(payload),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority,
    };

    await db.syncQueue.add(item);
  });
}

/**
 * Fetch pending sync items (ordered by priority and creation time)
 */
/**
 * Fetch every sync-queue item regardless of status.
 *
 * Used by the dev sync-simulation playground to render the raw queue. The
 * production sync loop uses `fetchPendingSyncItems` (status-filtered).
 *
 * @returns All SyncQueueItem rows.
 */
export async function fetchAllSyncQueueItems(): Promise<SyncQueueItem[]> {
  return db.syncQueue.toArray();
}

export async function fetchPendingSyncItems(): Promise<SyncQueueItem[]> {
  return db.syncQueue
    .where('[status+priority+createdAt]')
    .between(
      [SyncStatus.PENDING, 0, ''],
      [SyncStatus.PENDING, Infinity, '\uffff']
    )
    .reverse()
    .toArray();
}

/**
 * Mark sync item as in progress
 */
export async function markSyncItemInProgress(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: SyncStatus.IN_PROGRESS,
    lastAttemptAt: currentTimestamp(),
  });
}

/**
 * Mark sync item as completed
 */
export async function markSyncItemCompleted(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: SyncStatus.COMPLETED,
    completedAt: currentTimestamp(),
  });
}

/**
 * Mark sync item as failed
 */
export async function markSyncItemFailed(
  id: string,
  error: string
): Promise<void> {
  const item = await db.syncQueue.get(id);
  if (!item) return;

  await db.syncQueue.update(id, {
    status: SyncStatus.FAILED,
    retryCount: item.retryCount + 1,
    lastError: error,
    lastAttemptAt: currentTimestamp(),
  });
}

/**
 * Delete sync item
 */
export async function deleteSyncItem(id: string): Promise<void> {
  await db.syncQueue.delete(id);
}

/**
 * Clear completed sync items
 */
export async function clearCompletedSyncItems(): Promise<void> {
  await db.syncQueue.where('status').equals(SyncStatus.COMPLETED).delete();
}

/**
 * Clear the entire sync queue. Used after a guest→account collision "switch"
 * (docs/GUEST_MODE.md §Upgrade): once the user has signed into the pre-existing
 * account, the discarded guest's anon-stamped PENDING pushes must not fire under
 * the new uid (they'd fail the Firestore owner check and surface as "changes
 * couldn't sync"). Mirrors iOS `AuthService.clearPendingSyncQueue`.
 */
export async function clearSyncQueue(): Promise<void> {
  await db.syncQueue.clear();
}

/**
 * Promote FAILED sync queue items back to PENDING when their backoff
 * window has elapsed and they're under the retry cap.
 *
 * Called at the top of `pushSync`. The Dexie `liveQuery` on the PENDING
 * count re-fires when items are promoted, which in turn triggers the
 * push-on-enqueue debounce — so promotion implicitly schedules a fresh
 * push attempt without needing an explicit kick.
 *
 * Items at or above `MAX_SYNC_RETRIES` are left FAILED indefinitely;
 * they require a fresh enqueue or a manual retry from the playground
 * dashboard. (Tracked separately if real users hit this in the wild.)
 *
 * @returns The number of items promoted.
 */
export async function promoteEligibleFailedItems(): Promise<number> {
  const failedItems = await db.syncQueue
    .where('status')
    .equals(SyncStatus.FAILED)
    .toArray();

  const now = Date.now();
  let promoted = 0;

  for (const item of failedItems) {
    if (item.retryCount >= MAX_SYNC_RETRIES) {
      // Item has exhausted retries — warn once per promote cycle so a
      // wedged queue is visible in devtools rather than silently
      // abandoned. `result.details` downstream still surfaces the
      // FAILED state in the playground dashboard.
      console.warn(
        `[sync] ${item.entityType}/${item.entityId} abandoned after ${item.retryCount} retries; last error: ${item.lastError ?? 'unknown'}`
      );
      continue;
    }
    const lastAttemptAtMs = item.lastAttemptAt
      ? new Date(item.lastAttemptAt).getTime()
      : null;
    if (!isFailedItemEligibleForRetry(item.retryCount, lastAttemptAtMs, now)) continue;

    await db.syncQueue.update(item.id, {
      status: SyncStatus.PENDING,
      lastError: undefined,
    });
    promoted++;
  }

  return promoted;
}

/**
 * Count FAILED sync-queue items that have exhausted their retry budget
 * (`retryCount >= MAX_SYNC_RETRIES`). These are exactly the items
 * `promoteEligibleFailedItems` refuses to re-promote — they sit FAILED
 * until a manual or network-regain retry recovers them.
 *
 * Cheap: a single full-table scan + in-memory count. The sync queue only
 * holds unsynced/failed rows (COMPLETED items are cleared), so it stays
 * small. Scans rather than `where('status')` because `status` has no
 * standalone Dexie index (only the `[status+priority+createdAt]` compound),
 * so an equality query on it would need compound-index emulation. Refreshed
 * onto the sync status after every push cycle so the UI can surface
 * "N changes couldn't sync".
 *
 * @returns The number of exhausted FAILED items.
 */
export async function countExhaustedSyncItems(): Promise<number> {
  const all = await db.syncQueue.toArray();
  return all.reduce(
    (n, item) =>
      item.status === SyncStatus.FAILED && item.retryCount >= MAX_SYNC_RETRIES
        ? n + 1
        : n,
    0
  );
}

/**
 * Reset every exhausted FAILED item back to a fresh PENDING state:
 * `retryCount → 0`, `lastError` cleared, `status → PENDING`. This gives
 * the regular backoff/promote machinery a clean slate to retry them.
 *
 * Setting items to PENDING re-fires the Dexie `liveQuery` on the PENDING
 * count (see `startSyncLoop`), which schedules a debounced push — so this
 * implicitly nudges a push cycle without importing the firebase-coupled
 * sync loop here (keeping this module firebase-free and unit-testable).
 * Callers wanting an immediate push (the manual Retry button, the
 * network-regain kick) additionally invoke `fullSync`.
 *
 * @returns The number of items reset.
 */
export async function retryExhaustedSyncItems(): Promise<number> {
  // One transaction so a reload mid-reset can't leave a partial batch
  // (mirrors the iOS twin's single write block). Idempotent either way,
  // but atomic beats self-healing.
  return db.transaction('rw', [db.syncQueue], async () => {
    const all = await db.syncQueue.toArray();
    const exhausted = all.filter(
      (item) =>
        item.status === SyncStatus.FAILED && item.retryCount >= MAX_SYNC_RETRIES
    );
    for (const item of exhausted) {
      await db.syncQueue.update(item.id, {
        status: SyncStatus.PENDING,
        retryCount: 0,
        lastError: undefined,
      });
    }
    return exhausted.length;
  });
}
