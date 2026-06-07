import {
  collection,
  doc,
  getDoc,
  getDocs,
  onSnapshot,
  setDoc,
  query,
  where,
  serverTimestamp,
  Timestamp,
  type Unsubscribe as FirestoreUnsubscribe,
} from 'firebase/firestore';
import { liveQuery } from 'dexie';
import { firestore, auth } from './config';
import { resolveConflict, type SyncableEntity } from './conflictResolver';
import { recordSyncEvent, recordSyncError, resetSyncStatus } from './syncStatus';
import { db } from '../db/database';
import {
  fetchPendingSyncItems,
  markSyncItemInProgress,
  markSyncItemCompleted,
  markSyncItemFailed,
  promoteEligibleFailedItems,
} from '../db/operations/syncQueue';
import {
  SyncOperationType,
  SyncStatus,
  UserSchema,
  BoardSchema,
  TaskSchema,
  TaskStepSchema,
  BoardTaskSchema,
  CompositeTaskSchema,
  CompositeNodeSchema,
  CompoundChildSchema,
  RecurringBoardTemplateSchema,
  DefaultPoolSchema,
  mergeUserPreferences,
  additiveMergeCount,
  needsAdditiveMerge,
  type User,
} from '@oybc/shared';
import { runBoardCascadeForTask } from '../db/operations/orchestration';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Entity types that can be synced, mapped to their Dexie table names
 * and Firestore subcollection paths under `users/{userId}/`.
 */
const SYNCABLE_COLLECTIONS = [
  'boards',
  'tasks',
  'taskSteps',                // legacy — kept so push can drain DELETE ops from migration v4
  'boardTasks',
  'compositeTasks',           // legacy — kept so push can drain DELETE ops from migration v4
  'compositeNodes',           // legacy — kept so push can drain DELETE ops from migration v4
  'compoundChildren',
  'recurringBoardTemplates',  // Phase 6.2
  'defaultPools',             // Phase 6.X — Default Pools
] as const;

type SyncCollection = (typeof SYNCABLE_COLLECTIONS)[number];

/**
 * Zod schema per syncable subcollection. Remote documents pulled from
 * Firestore are validated against these before being applied to the
 * local Dexie row. A failure is logged and the document is skipped —
 * the safety-net pull will retry on the next cycle.
 *
 * Defense-in-depth: Firestore rules already gate write shape, but a
 * compromised client, SDK bug, or future schema change could emit a
 * malformed document. Validating on read prevents corrupted rows from
 * slipping into the local source-of-truth database.
 */
// Each schema's `safeParse` returns a discriminated union — narrowing to
// the common shape gives us a single callable type to map across
// collections without pulling zod itself into web's dependency graph.
type RemoteSchema = {
  safeParse: (input: unknown) =>
    | { success: true; data: unknown }
    | { success: false; error: { issues: Array<{ path: (string | number)[]; message: string }> } };
};

const COLLECTION_SCHEMAS: Record<SyncCollection, RemoteSchema> = {
  boards: BoardSchema,
  tasks: TaskSchema,
  taskSteps: TaskStepSchema,
  boardTasks: BoardTaskSchema,
  compositeTasks: CompositeTaskSchema,
  compositeNodes: CompositeNodeSchema,
  compoundChildren: CompoundChildSchema,
  recurringBoardTemplates: RecurringBoardTemplateSchema,
  defaultPools: DefaultPoolSchema,
};

/**
 * Subset of syncable collections whose documents carry a top-level
 * `userId` field. For these, the pull path must reject any document
 * whose `userId` doesn't match the authenticated user — a defense
 * against a compromised peer that writes into its own path with a
 * spoofed `userId` and hopes that a future cross-user share path
 * surfaces it.
 */
const USER_SCOPED_COLLECTIONS: ReadonlySet<SyncCollection> = new Set([
  'boards',
  'tasks',
  'compositeTasks',
  'recurringBoardTemplates',
  'defaultPools',
]);

/**
 * Legacy collections kept in SYNCABLE_COLLECTIONS so the push path can drain
 * DELETE ops produced by the migration-v4 cleanup. The pull path skips them
 * because their Firestore subcollections are either empty or being actively
 * retired — pulling their docs would resurrect legacy rows in local Dexie.
 */
const LEGACY_PULL_SKIP_COLLECTIONS: ReadonlySet<SyncCollection> = new Set([
  'taskSteps',
  'compositeTasks',
  'compositeNodes',
]);

export interface PushResult {
  pushed: number;
  conflicts: number;
  failed: number;
  details: string[];
}

export interface PullResult {
  pulled: number;
  conflicts: number;
  details: string[];
}

export interface SyncResult {
  push: PushResult;
  pull: PullResult;
}

// ─── Phase 4: lastSyncedCount bookkeeping after push ─────────────────────────

/**
 * After a successful push of a COUNTING task to Firestore, advance the local
 * `lastSyncedCount` to the pushed `currentCount` value. This records
 * "Firestore now knows about this count" so the next conflict resolution can
 * compute the local delta correctly.
 *
 * This is a targeted write (no version bump, no sync queue entry) — it is sync
 * bookkeeping, not a user edit. Only counting tasks carry `lastSyncedCount`.
 *
 * @param entityType - The entity type from the sync queue item.
 * @param entityId - The task ID.
 * @param payload - The sync payload that was just pushed to Firestore.
 */
async function updateLastSyncedCountAfterPush(
  entityType: string,
  entityId: string,
  payload: SyncableEntity,
): Promise<void> {
  if (entityType !== 'tasks') return;
  const payloadAsTask = payload as { type?: string; currentCount?: number };
  if (payloadAsTask.type !== 'counting') return;
  const pushedCount = payloadAsTask.currentCount;
  if (typeof pushedCount !== 'number') return;

  try {
    // Targeted update — does NOT bump version or write a new sync queue entry.
    // lastSyncedCount is sync bookkeeping only.
    await db.tasks.update(entityId, { lastSyncedCount: pushedCount });
  } catch (err) {
    // Non-fatal: if this write fails, the next conflict will fall back to LWW
    // (null lastSyncedCount → LWW). Log but do not propagate.
    console.warn(`[sync] Could not advance lastSyncedCount for tasks/${entityId}:`, err);
  }
}

// ─── Push Sync ────────────────────────────────────────────────────────────────

/**
 * Pushes pending sync queue items to Firestore.
 *
 * For each pending item:
 * 1. Marks it IN_PROGRESS
 * 2. Reads the remote document (if exists) for conflict check
 * 3. Resolves conflicts using LWW
 * 4. Writes to Firestore if local wins (or remote doesn't exist)
 * 5. Updates local DB if remote wins
 * 6. Marks the queue item COMPLETED or FAILED
 *
 * @param userId - The authenticated user's ID (for Firestore path)
 * @returns Push result summary
 */
export async function pushSync(userId: string): Promise<PushResult> {
  const result: PushResult = { pushed: 0, conflicts: 0, failed: 0, details: [] };

  // Reset stale IN_PROGRESS items (e.g., from a crash/reload mid-sync).
  // Wrapped in try/catch so a Dexie failure here doesn't silently abort
  // the push loop — a wedged reset would otherwise leave queue items
  // stuck in IN_PROGRESS forever, invisible to the UI.
  try {
    const staleItems = await db.syncQueue
      .where('status')
      .equals(SyncStatus.IN_PROGRESS)
      .toArray();
    for (const stale of staleItems) {
      try {
        await db.syncQueue.update(stale.id, { status: SyncStatus.PENDING });
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        console.error(`[sync] Failed to reset stale queue item ${stale.id}:`, err);
        recordSyncError(errorMsg);
      }
    }
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    console.error('[sync] Failed to query stale queue items:', err);
    recordSyncError(errorMsg);
  }

  // Promote FAILED items whose backoff window has elapsed back to PENDING
  // so the same loop picks them up. Promotion also re-fires the Dexie
  // liveQuery on PENDING count, so even if this push doesn't drain them
  // (rare), the next debounce will.
  await promoteEligibleFailedItems();

  const pendingItems = await fetchPendingSyncItems();
  if (pendingItems.length === 0) return result;

  for (const item of pendingItems) {
    try {
      await markSyncItemInProgress(item.id);

      const entityType = item.entityType as SyncCollection | 'users';
      const payload = JSON.parse(item.payload) as SyncableEntity;

      // The `users` entity lives at `users/{userId}` (the parent scope doc),
      // not in a `users/{userId}/users` subcollection, so it has a dedicated
      // docRef. Every other entity is a subcollection child under the user.
      const docRef =
        entityType === 'users'
          ? doc(firestore, 'users', item.entityId)
          : doc(firestore, 'users', userId, entityType, item.entityId);

      // User entities are never DELETE-synced; clearing the user doc would
      // remove the scope root for every other collection.
      if (entityType === 'users' && item.operationType === SyncOperationType.DELETE) {
        await markSyncItemCompleted(item.id);
        result.details.push(`Skipped delete for users/${item.entityId}`);
        continue;
      }

      if (item.operationType === SyncOperationType.DELETE) {
        // Deletes still check conflict resolution — don't overwrite a newer remote version
        const remoteDeleteSnap = await getDoc(docRef);
        if (remoteDeleteSnap.exists()) {
          const remoteData = remoteDeleteSnap.data() as SyncableEntity;
          const resolution = resolveConflict(payload, remoteData);
          if (resolution.winner === 'remote') {
            // Remote is newer — don't delete, keep remote version locally
            const table = db.table(entityType);
            await table.put(remoteData);
            await markSyncItemCompleted(item.id);
            result.conflicts++;
            recordSyncEvent('conflict');
            result.details.push(`Delete conflict ${entityType}/${item.entityId}: remote wins (v${remoteData.version})`);
            continue;
          }
        }
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        result.pushed++;
        recordSyncEvent('pushed');
        result.details.push(`Deleted ${entityType}/${item.entityId}`);
        continue;
      }

      // Check for remote version
      const remoteSnap = await getDoc(docRef);

      if (!remoteSnap.exists()) {
        // No remote — push directly
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        // Phase 4: After a successful push of a counting task, advance
        // lastSyncedCount so subsequent conflicts can compute the local delta.
        await updateLastSyncedCountAfterPush(entityType, item.entityId, payload);
        result.pushed++;
        recordSyncEvent('pushed');
        result.details.push(`Pushed ${entityType}/${item.entityId} (new)`);
        continue;
      }

      // Remote exists — resolve conflict
      const remoteData = remoteSnap.data() as SyncableEntity;
      const resolution = resolveConflict(payload, remoteData);

      if (resolution.winner === 'local') {
        // Local wins — push to Firestore
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        // Phase 4: After a successful local-wins push of a counting task,
        // advance lastSyncedCount so subsequent conflicts can compute the
        // local delta correctly.
        await updateLastSyncedCountAfterPush(entityType, item.entityId, payload);
        result.pushed++;
        recordSyncEvent('pushed');
        result.details.push(
          `Pushed ${entityType}/${item.entityId} (local v${payload.version} > remote v${remoteData.version})`
        );
      } else {
        // Remote wins — update local DB with remote data
        const table = db.table(entityType);
        await table.put(remoteData);
        await markSyncItemCompleted(item.id);
        result.conflicts++;
        recordSyncEvent('conflict');
        result.details.push(
          `Conflict ${entityType}/${item.entityId}: remote wins (v${remoteData.version} >= v${payload.version})`
        );
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      console.error(`Sync push failed for ${item.entityType}/${item.entityId}:`, err);
      await markSyncItemFailed(item.id, errorMsg);
      result.failed++;
      recordSyncEvent('failed');
      recordSyncError(errorMsg);
      result.details.push(`Failed ${item.entityType}/${item.entityId}: ${errorMsg}`);
    }
  }

  return result;
}

// ─── Pull Sync ────────────────────────────────────────────────────────────────

/**
 * Pulls remote changes from Firestore that are newer than the local lastSyncedAt.
 *
 * For each syncable collection:
 * 1. Queries Firestore for documents updated after lastSyncedAt
 * 2. For each document, compares with local version
 * 3. Resolves conflicts using LWW
 * 4. Applies winning data to local DB
 *
 * @param userId - The authenticated user's ID
 * @param lastSyncedAt - ISO8601 timestamp of the last successful sync
 * @returns Pull result summary
 */
/**
 * Apply a remote `users/{userId}` payload to the local Dexie row,
 * running the same validation + LWW resolution as the polling pull
 * path. Used by `pullSync` (safety-net path) and the snapshot
 * listener (real-time path).
 *
 * @returns A short status string for logging; `null` if nothing
 *   meaningful happened (e.g. malformed payload skipped).
 */
async function applyRemoteUserDoc(
  userId: string,
  remoteUserData: unknown
): Promise<string | null> {
  // Validate the parent-doc payload before trusting it. A malformed /
  // legacy user doc (missing id/version, wrong types, etc.) would
  // otherwise slip straight into `db.users.put` and corrupt the local
  // user row. `UserSchema.safeParse` enforces id + version + timestamp
  // invariants; enforce the id-equals-userId check separately because
  // the schema only asserts "some non-empty string".
  //
  // A validation failure is logged and the user doc is skipped — callers
  // should NOT flip a "pull errored" flag on this path: an empty/invalid
  // email shouldn't deadlock the rest of the sync loop.
  const parsed = UserSchema.safeParse(remoteUserData);
  if (!parsed.success || parsed.data.id !== userId) {
    const reason = !parsed.success
      ? parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join(', ')
      : `id ${String((remoteUserData as { id?: unknown }).id)} ≠ userId ${userId}`;
    return `Skipped malformed users/${userId}: ${reason}`;
  }

  // Re-run preferences through the quarantine merge so any out-of-range
  // field values produced by a misbehaving peer are substituted with
  // defaults before they reach Dexie.
  const remoteUser: User = {
    ...parsed.data,
    preferences: mergeUserPreferences(parsed.data.preferences),
  };
  const remoteSyncable = remoteUser as unknown as SyncableEntity;
  const localUser = await db.users.get(userId);
  const localSyncable = localUser as SyncableEntity | undefined;
  if (!localUser) {
    await db.users.put(remoteUser);
    recordSyncEvent('pulled');
    return `Pulled users/${userId} (new)`;
  }
  const resolution = resolveConflict(localSyncable!, remoteSyncable);
  if (resolution.winner === 'remote') {
    // Preserve the local `lastSyncedAt` watermark through a pull.
    await db.users.put({
      ...remoteUser,
      lastSyncedAt: localUser.lastSyncedAt ?? remoteUser.lastSyncedAt,
    });
    recordSyncEvent('pulled');
    return `Pulled users/${userId} (remote v${remoteSyncable.version} > local v${localSyncable!.version})`;
  }
  return null; // local-wins → silent no-op
}

/**
 * Apply a remote document from a syncable subcollection to the local
 * Dexie table, running LWW conflict resolution. Used by `pullSync` and
 * the per-collection snapshot listener.
 *
 * Validates the payload against the Zod schema for the collection
 * before touching Dexie. A failed parse (missing fields, wrong types,
 * version < 1, userId mismatch for user-scoped collections) logs a
 * `Skipped` status and returns without writing — corrupted remote data
 * must never reach the local source-of-truth DB.
 *
 * @param collectionName The Firestore subcollection being pulled.
 * @param remoteData The raw document data from Firestore (untrusted).
 * @param authenticatedUserId The current user's uid, for userId scope
 *   checks on user-scoped collections.
 * @returns A short status string for logging; `null` if local-wins.
 */
async function applyRemoteSubdoc(
  collectionName: SyncCollection,
  remoteData: unknown,
  authenticatedUserId: string
): Promise<string | null> {
  const schema = COLLECTION_SCHEMAS[collectionName];
  const parsed = schema.safeParse(remoteData);
  if (!parsed.success) {
    const reason = parsed.error.issues
      .map((i) => `${i.path.join('.')}: ${i.message}`)
      .join(', ');
    const id =
      typeof (remoteData as { id?: unknown })?.id === 'string'
        ? (remoteData as { id: string }).id
        : '?';
    return `Skipped malformed ${collectionName}/${id}: ${reason}`;
  }

  const validated = parsed.data as SyncableEntity;

  // Guard against a peer writing a document with a spoofed `userId`
  // into its own path — reject anything that doesn't match the
  // authenticated user on user-scoped collections.
  //
  // The status string omits both the payload and authenticated uids
  // because it flows through `console.debug('[sync]', status)` in the
  // snapshot listener; log collection or a screenshot would otherwise
  // leak stable identifiers. The collection + doc id is enough to
  // triage in practice; the full uids are already one query away in
  // Dexie if needed.
  if (USER_SCOPED_COLLECTIONS.has(collectionName)) {
    const payloadUserId = (validated as { userId?: unknown }).userId;
    if (payloadUserId !== authenticatedUserId) {
      return `Skipped ${collectionName}/${validated.id}: userId mismatch`;
    }
  }

  // CompoundChild has no `userId` column — children scope through their
  // parent compound's userId. A crafted Firestore doc with a `compoundTaskId`
  // pointing at another user's compound would land in local Dexie with no
  // direct check. Resolve the parent and reject on mismatch.
  if (collectionName === 'compoundChildren') {
    const compoundTaskId = (validated as { compoundTaskId?: unknown }).compoundTaskId;
    if (typeof compoundTaskId !== 'string' || !compoundTaskId) {
      return `Skipped compoundChildren/${validated.id}: missing compoundTaskId`;
    }
    const parentTask = await db.tasks.get(compoundTaskId);
    if (!parentTask) {
      // No local parent — could be a legitimate cross-device race. Defer:
      // skip this pull cycle, the safety net will retry. Don't accept blind.
      return `Skipped compoundChildren/${validated.id}: parent compound not yet present locally`;
    }
    if (parentTask.userId !== authenticatedUserId) {
      return `Skipped compoundChildren/${validated.id}: parent userId mismatch`;
    }
  }

  const table = db.table(collectionName);
  const localData = (await table.get(validated.id)) as SyncableEntity | undefined;

  const isNew = !localData;
  const remoteWins = isNew || resolveConflict(localData!, validated).winner === 'remote';

  if (!remoteWins) {
    return null; // local-wins → silent no-op
  }

  // Apply the remote row to local Dexie, with additive-merge for counting
  // source tasks (Phase 4). The cascade runs in the same transaction so a
  // cascade failure rolls back the upsert — pulled value is authoritative
  // except when additive merge overrides currentCount.
  //
  // Additive merge fires when ALL of:
  //   1. collectionName === 'tasks' (not other entity types)
  //   2. The remote task is a COUNTING task
  //   3. The local task exists and has a known lastSyncedCount
  //   4. Both local and remote currentCount deviate from lastSyncedCount
  //      (concurrent increments — needsAdditiveMerge returns true)
  //   5. At least one linked task references this task as a source
  //      (sharedCounterId === this task's id) — additive merge only pays
  //      off for sources (the accumulator that multiple views read).
  //
  // When merge fires, the merged count replaces the remote count, version
  // is bumped, and a push entry is enqueued so the merged value reaches
  // Firestore. The cascade then re-derives all linked tasks + board stats.
  let mergeLog: string | null = null;
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // Phase 4 — Additive merge for shared-counter sources on pull.
      //
      // Guard: skip merge when either side is a tombstone. A deleted task
      // must fall through to standard LWW which handles isDeleted correctly;
      // running additive merge on a delete would resurrect the record.
      const remoteIsDeleted = !!(validated as { isDeleted?: boolean }).isDeleted;
      const localIsDeleted = !!(localData as { isDeleted?: boolean } | undefined)?.isDeleted;

      if (
        collectionName === 'tasks' &&
        !isNew &&
        localData &&
        !remoteIsDeleted &&
        !localIsDeleted
      ) {
        const remoteTask = validated as { type?: string; currentCount?: number };
        const localTask = localData as { type?: string; currentCount?: number; lastSyncedCount?: number | null; version?: number };

        if (remoteTask.type === 'counting') {
          const localCount = typeof localTask.currentCount === 'number' ? localTask.currentCount : 0;
          const remoteCount = typeof remoteTask.currentCount === 'number' ? remoteTask.currentCount : 0;
          const lastSynced = typeof localTask.lastSyncedCount === 'number' ? localTask.lastSyncedCount : null;

          if (needsAdditiveMerge(localCount, remoteCount, lastSynced)) {
            // Check if this task is a shared-counter source (any task references it).
            const linkedCount = await db.tasks
              .where('sharedCounterId')
              .equals(validated.id)
              .and((t) => !t.isDeleted)
              .count();

            if (linkedCount > 0) {
              // Additive merge applies: sum local delta on top of remote count.
              const { merged } = additiveMergeCount(localCount, remoteCount, lastSynced);

              // version = max(local, remote) + 1 so LWW on next pull doesn't
              // silently discard the merge if the remote has version > local + 1.
              const localVersion = typeof localTask.version === 'number' ? localTask.version : 0;
              const remoteVersion = typeof (validated as { version?: number }).version === 'number'
                ? (validated as { version?: number }).version!
                : 0;
              const newVersion = Math.max(localVersion, remoteVersion) + 1;
              const now = new Date().toISOString();

              // 1. Apply the full remote record (preserves all remote-changed
              //    fields: title, description, isDeleted, maxCount, etc.)
              await table.put(validated);

              // 2. Layer the additively-merged count fields on top of the
              //    remote upsert so the merged count wins.
              await db.tasks.update(validated.id, {
                currentCount: merged,
                lastSyncedCount: remoteCount, // common ancestor advances to remote
                version: newVersion,
                updatedAt: now,
              });

              // Enqueue push so the merged value reaches Firestore.
              const mergedTask = await db.tasks.get(validated.id);
              if (mergedTask) {
                await db.syncQueue.add({
                  id: crypto.randomUUID(),
                  entityType: 'tasks',
                  entityId: validated.id,
                  operationType: SyncOperationType.UPDATE,
                  payload: JSON.stringify(mergedTask),
                  status: SyncStatus.PENDING,
                  retryCount: 0,
                  createdAt: now,
                  priority: 0,
                });
              }

              mergeLog = `additive-merge currentCount ${localCount}+${remoteCount}-${lastSynced}=${merged}`;
              // Run cascade on the merged task (re-derives linked tasks + board stats).
              await runBoardCascadeForTask(validated.id);
              return; // Merge path complete — skip the standard table.put below.
            }
          }
        }
      }

      await table.put(validated);

      // Issue #5 (remote-wins LWW on counting task): advance lastSyncedCount
      // so the next conflict can compute the local delta correctly.
      // The remote doc is not guaranteed to carry the correct per-device
      // lastSyncedCount (it's local bookkeeping), so we write it explicitly.
      if (collectionName === 'tasks' && !isNew) {
        const remoteTask = validated as { type?: string; currentCount?: number };
        if (remoteTask.type === 'counting' && typeof remoteTask.currentCount === 'number') {
          await db.tasks.update(validated.id, {
            lastSyncedCount: remoteTask.currentCount,
          });
        }
      }

      // After pulling a Task or CompoundChild, cascade the board derivation
      // pass so that any board containing the changed task recomputes its
      // stats + status transitions. The cascade writes boards + sync queue
      // entries but does NOT touch the Task itself — pulled value is final.
      //
      // Cascade unconditionally (matches iOS SyncService.runPullCascade).
      // The previous `completionChanged` gate (isCompleted/currentCount diff)
      // missed compound-affecting edits — operator/threshold/isOrdered changes
      // would leave boards with stale stats + completedLineIds even though
      // the compound's derived state had flipped. The cascade is idempotent
      // and small-N, so always running it is the safer + iOS-parity choice.
      if (collectionName === 'tasks') {
        // Let cascade errors propagate so the outer Dexie transaction rolls
        // back the `table.put(validated)` that just landed. Pulling will retry
        // on the next cycle. Previously this branch swallowed errors, which
        // left the task applied locally but board stats stale forever — a
        // silent divergence that no safety net resolved.
        await runBoardCascadeForTask(validated.id);
      } else if (collectionName === 'compoundChildren') {
        // For a pulled CompoundChild, cascade via the parent compound task.
        const compoundTaskId = (validated as { compoundTaskId?: unknown }).compoundTaskId;
        if (typeof compoundTaskId === 'string' && compoundTaskId) {
          await runBoardCascadeForTask(compoundTaskId);
        }
      }
    },
  );

  recordSyncEvent('pulled');
  if (isNew) {
    return `Pulled ${collectionName}/${validated.id} (new)`;
  }
  if (mergeLog) {
    return `Pulled ${collectionName}/${validated.id} (additive-merge: ${mergeLog})`;
  }
  return `Pulled ${collectionName}/${validated.id} (remote v${validated.version} > local v${(localData as SyncableEntity).version})`;
}

export async function pullSync(
  userId: string,
  lastSyncedAt?: string,
): Promise<PullResult> {
  const result: PullResult = { pulled: 0, conflicts: 0, details: [] };
  let hadPullError = false;

  // Pull the user doc (lives at `users/{userId}`, not a subcollection) so
  // synced profile fields like `preferences` replicate back to this device.
  try {
    const userDocRef = doc(firestore, 'users', userId);
    const userSnap = await getDoc(userDocRef);
    if (userSnap.exists()) {
      const status = await applyRemoteUserDoc(userId, userSnap.data());
      if (status) {
        if (status.startsWith('Pulled')) result.pulled++;
        else if (status.startsWith('Skipped')) {
          /* skipped — not an error */
        }
        result.details.push(status);
      } else {
        result.conflicts++;
        result.details.push(`Kept local users/${userId} (local-wins)`);
      }
    }
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    result.details.push(`Pull failed for users/${userId}: ${errorMsg}`);
    hadPullError = true;
  }

  for (const collectionName of SYNCABLE_COLLECTIONS) {
    // Legacy collections are kept in SYNCABLE_COLLECTIONS so push can drain
    // their DELETE ops, but we must NOT pull from them — doing so would
    // resurrect retired rows in local Dexie.
    if (LEGACY_PULL_SKIP_COLLECTIONS.has(collectionName)) continue;

    try {
      const colRef = collection(firestore, 'users', userId, collectionName);

      // Query for documents updated since last sync. `_syncedAt` is a
      // Firestore `Timestamp`; the local watermark is an ISO string.
      // Convert before querying — see `attachPullListeners` for the
      // type-mismatch story.
      const q = lastSyncedAt
        ? query(colRef, where('_syncedAt', '>', Timestamp.fromDate(new Date(lastSyncedAt))))
        : query(colRef); // First sync — pull everything

      const snapshot = await getDocs(q);
      if (snapshot.empty) continue;

      for (const docSnap of snapshot.docs) {
        const remoteData = docSnap.data();
        const status = await applyRemoteSubdoc(collectionName, remoteData, userId);
        if (status) {
          if (status.startsWith('Pulled')) result.pulled++;
          // Skipped-malformed / userId-mismatch statuses are not conflicts;
          // just log them and move on so the pull loop isn't wedged.
          result.details.push(status);
        } else {
          result.conflicts++;
          const remoteId =
            typeof (remoteData as { id?: unknown })?.id === 'string'
              ? (remoteData as { id: string }).id
              : '?';
          result.details.push(
            `Kept local ${collectionName}/${remoteId} (local-wins)`
          );
        }
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      result.details.push(`Pull failed for ${collectionName}: ${errorMsg}`);
      hadPullError = true;
    }
  }

  // Only advance the watermark if pull completed without errors,
  // otherwise we risk permanently skipping updates for failed collections.
  if (!hadPullError) {
    const now = new Date().toISOString();
    const user = await db.users.get(userId);
    if (user) {
      await db.users.update(userId, { lastSyncedAt: now });
    }
  }

  return result;
}

/**
 * Attach Firestore `onSnapshot` listeners for the parent user doc and
 * every syncable subcollection. Each listener feeds remote changes
 * through the same `applyRemoteUserDoc` / `applyRemoteSubdoc` handlers
 * that the safety-net `pullSync` uses, so all incoming-write logic is
 * unified.
 *
 * Each per-collection listener is filtered by `_syncedAt > lastSyncedAt`
 * so the initial attach only delivers post-watermark documents (avoids
 * a full collection scan on every reload). The user-doc listener has no
 * filter — it's a single document.
 *
 * Returns an unsubscribe function that detaches all listeners.
 *
 * @param userId - The authenticated user's ID
 * @param lastSyncedAt - ISO8601 watermark; `undefined` triggers a full
 *   first-sync delivery on attach (matches existing pull semantics)
 */
export function attachPullListeners(
  userId: string,
  lastSyncedAt: string | undefined
): () => void {
  const unsubs: FirestoreUnsubscribe[] = [];

  // Parent user doc — single document, no watermark filter needed.
  //
  // Error messages avoid interpolating `userId`: a dev-tools-open user
  // or a future error-reporting integration shouldn't learn the
  // authenticated uid from a routine listener failure. The `[sync]`
  // tag plus the error content is enough to triage.
  const userDocRef = doc(firestore, 'users', userId);
  const userUnsub = onSnapshot(
    userDocRef,
    async (snap) => {
      if (!snap.exists()) return;
      try {
        const status = await applyRemoteUserDoc(userId, snap.data());
        if (status) console.debug('[sync]', status);
      } catch (err) {
        console.error('[sync] user-doc listener failed:', err);
      }
    },
    (err) => console.error('[sync] user-doc listener error:', err)
  );
  unsubs.push(userUnsub);

  // One listener per subcollection, filtered to deltas since the last
  // safety-net watermark so initial attach is bounded.
  //
  // `_syncedAt` is written via `serverTimestamp()` and stored as a
  // Firestore `Timestamp`. `lastSyncedAt` on the local user row is an
  // ISO8601 string (set from the local clock at the end of `pullSync`).
  // Firestore range queries require both sides of the comparison to be
  // the same type — comparing Timestamp > String never matches because
  // Firestore's canonical type ordering puts every Timestamp below every
  // String. Convert the watermark to a Timestamp here.
  //
  // A small clock-skew window (local clock vs server clock at write
  // time) can leak past the watermark; the safety-net `pullSync` will
  // pick up anything missed.
  const watermarkDate = lastSyncedAt
    ? new Date(lastSyncedAt)
    : new Date(0); // Unix epoch — first-sync delivery
  const watermarkTs = Timestamp.fromDate(watermarkDate);
  for (const collectionName of SYNCABLE_COLLECTIONS) {
    // Legacy collections are kept in SYNCABLE_COLLECTIONS so push can drain
    // their DELETE ops, but we must NOT attach real-time listeners to them.
    if (LEGACY_PULL_SKIP_COLLECTIONS.has(collectionName)) continue;

    const colRef = collection(firestore, 'users', userId, collectionName);
    const q = query(colRef, where('_syncedAt', '>', watermarkTs));
    const unsub = onSnapshot(
      q,
      async (snapshot) => {
        for (const change of snapshot.docChanges()) {
          if (change.type === 'removed') continue; // soft-deletes only; no real removes
          try {
            const remoteData = change.doc.data();
            const status = await applyRemoteSubdoc(collectionName, remoteData, userId);
            if (status) console.debug('[sync]', status);
          } catch (err) {
            console.error(`[sync] ${collectionName} listener apply failed:`, err);
          }
        }
      },
      (err) => console.error(`[sync] ${collectionName} listener error:`, err)
    );
    unsubs.push(unsub);
  }

  return () => {
    for (const unsub of unsubs) unsub();
  };
}

// ─── Full Sync ────────────────────────────────────────────────────────────────

/**
 * Performs a full sync cycle: push local changes, then pull remote changes.
 *
 * @param userId - The authenticated user's ID
 * @returns Combined push and pull results
 */
export async function fullSync(userId: string): Promise<SyncResult> {
  // Defense-in-depth: verify userId matches the authenticated user
  if (auth.currentUser?.uid !== userId) {
    throw new Error('Sync userId does not match authenticated user');
  }

  // Get lastSyncedAt before pushing (so we don't miss changes during push)
  const user = await db.users.get(userId);
  const lastSyncedAt = user?.lastSyncedAt;

  const push = await pushSync(userId);
  const pull = await pullSync(userId, lastSyncedAt);

  return { push, pull };
}

// ─── Background Sync Loop ─────────────────────────────────────────────────────

/**
 * Starts a background sync loop that runs push+pull on an interval.
 *
 * Pauses when offline (`navigator.onLine` is false) and resumes
 * when back online. Returns a cleanup function for useEffect.
 *
 * @param userId - The authenticated user's ID
 * @param intervalMs - Sync interval in milliseconds (default 30s)
 * @returns Cleanup function that stops the loop
 */
/**
 * Safety-net interval for the periodic full sync. With push-on-enqueue
 * handling normal local-write replication, this only needs to fire
 * occasionally to:
 *   - retry items stuck in FAILED that didn't trigger fresh enqueues
 *   - reset stale IN_PROGRESS items left over from a crashed tab
 *   - back-stop missed Firestore snapshot deliveries (rare)
 * 5 minutes is well below typical user dwell time and keeps Firestore
 * read load minimal.
 */
export const SYNC_SAFETY_NET_MS = 5 * 60 * 1000;

/** Debounce window before a queue-driven push fires. Coalesces bursts of
 *  rapid local writes (e.g. a slider that emits per-tick) into one push. */
const PUSH_DEBOUNCE_MS = 500;

export function startSyncLoop(
  userId: string,
  intervalMs: number = SYNC_SAFETY_NET_MS,
): () => void {
  let timer: ReturnType<typeof setInterval> | null = null;
  let pushDebounceTimer: ReturnType<typeof setTimeout> | null = null;
  let isSyncing = false;
  // Set when a push was requested (debounce fired) but skipped because
  // a sync was already in-flight. The active fullTick / pushTick will
  // schedule a follow-up push in its `finally` so the requested work
  // doesn't sit until the safety-net interval. Without this, a queue
  // item enqueued mid-fullTick would not re-fire the liveQuery (the
  // count didn't change between observations) and would wait up to 5 min.
  let needsPush = false;

  async function fullTick(): Promise<void> {
    if (isSyncing || !navigator.onLine) return;
    isSyncing = true;
    try {
      await fullSync(userId);
    } catch (err) {
      console.error('Sync loop error:', err);
    } finally {
      isSyncing = false;
      if (needsPush) {
        needsPush = false;
        scheduleFlush();
      }
    }
  }

  async function pushTick(): Promise<void> {
    if (!navigator.onLine) return;
    if (isSyncing) {
      needsPush = true;
      return;
    }
    isSyncing = true;
    try {
      await pushSync(userId);
    } catch (err) {
      console.error('Sync push error:', err);
    } finally {
      isSyncing = false;
      if (needsPush) {
        needsPush = false;
        scheduleFlush();
      }
    }
  }

  /** Schedule a debounced push. Repeated calls within the window collapse
   *  into one. If a push is already running, the trailing-edge fire still
   *  schedules — the queue observation will re-fire when state changes. */
  function scheduleFlush(): void {
    if (pushDebounceTimer) clearTimeout(pushDebounceTimer);
    pushDebounceTimer = setTimeout(() => {
      pushDebounceTimer = null;
      void pushTick();
    }, PUSH_DEBOUNCE_MS);
  }

  // Push-on-enqueue: react to any change in the pending sync queue. When
  // an op enqueues a new item (or a previously-failed item re-becomes
  // pending after retry), the count rises and we schedule a debounced
  // push. This collapses the up-to-30s wait the polling model imposed
  // down to ~PUSH_DEBOUNCE_MS + Firestore RTT.
  const pendingObservation = liveQuery(() =>
    db.syncQueue.where('status').equals(SyncStatus.PENDING).count()
  );
  const pendingSubscription = pendingObservation.subscribe({
    next: (count) => {
      if (count > 0) scheduleFlush();
    },
    error: (err) => console.error('Sync queue observation error:', err),
  });

  // Real-time pull: open Firestore listeners for the parent user doc and
  // every syncable subcollection. Initial attach delivers everything
  // newer than the last persisted watermark, then real-time changes flow
  // in continuously. Detached on cleanup.
  //
  // The watermark fetch is async, so attach happens on the next tick.
  // Track teardown state with a flag so a cleanup that fires before the
  // async attach resolves still tears the listeners down — otherwise an
  // account switch could leak listeners that hold Firestore subscriptions
  // open against the previous user's data.
  let detachListeners: (() => void) | null = null;
  let cleanedUp = false;
  void (async () => {
    try {
      const initialUser = await db.users.get(userId);
      if (cleanedUp) return;
      detachListeners = attachPullListeners(userId, initialUser?.lastSyncedAt);
      if (cleanedUp) {
        // Cleanup raced in between the await and the assignment. Detach
        // immediately so the listeners we just created don't leak.
        detachListeners();
        detachListeners = null;
      }
    } catch (err) {
      console.error('Failed to attach pull listeners:', err);
    }
  })();

  // Safety-net interval: full pull + retry-eligible push.
  timer = setInterval(() => void fullTick(), intervalMs);

  // Also sync immediately when coming back online — recovers anything
  // that piled up during the offline window. Firestore SDK auto-resumes
  // listener subscriptions on reconnect, but a kick to fullTick covers
  // any race + advances the safety-net watermark.
  function handleOnline(): void {
    void fullTick();
  }
  window.addEventListener('online', handleOnline);

  // Run an initial sync immediately (covers first sign-in + reload while
  // the listeners warm up).
  void fullTick();

  // Cleanup
  return () => {
    cleanedUp = true;
    if (timer) clearInterval(timer);
    if (pushDebounceTimer) clearTimeout(pushDebounceTimer);
    pendingSubscription.unsubscribe();
    if (detachListeners) {
      detachListeners();
      detachListeners = null;
    }
    window.removeEventListener('online', handleOnline);
    // Counters are session-scoped — drop them when the loop tears down
    // so the next sign-in starts from zero.
    resetSyncStatus();
  };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Writes a single document to Firestore, stripping undefined values.
 */
async function writeSingleDoc(
  docRef: ReturnType<typeof doc>,
  data: Record<string, unknown>,
): Promise<void> {
  // Firestore doesn't accept undefined values — strip them
  const cleaned: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    if (value !== undefined) {
      cleaned[key] = value;
    }
  }
  cleaned._syncedAt = serverTimestamp();

  await setDoc(docRef, cleaned, { merge: true });
}
