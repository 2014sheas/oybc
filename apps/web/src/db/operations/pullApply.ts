import {
  BoardSchema,
  TaskSchema,
  TaskStepSchema,
  BoardTaskSchema,
  CompositeTaskSchema,
  CompositeNodeSchema,
  CompoundChildSchema,
  RecurringBoardTemplateSchema,
  DefaultPoolSchema,
  PoolSchema,
  CoreBoardDefaultSchema,
  TaskEventSchema,
  USER_SCOPED_SYNC_COLLECTIONS,
  SyncOperationType,
  type SyncCollection,
} from '@oybc/shared';
import { db } from '../internal';
import { resolveConflict, type SyncableEntity } from '../../firebase/conflictResolver';
import { recordSyncEvent } from '../../firebase/syncStatus';
import { runBoardCascadeForTask, runBoardCascadeForBoardId } from './orchestration';
import { reDeriveSealedBoardsByIds } from './sealing';
import { addToSyncQueue } from './syncQueue';

/**
 * Apply a remote document from a syncable subcollection to the local Dexie
 * table, running LWW conflict resolution. Used by `firebase/syncService.ts`
 * (`pullSync` and the per-collection snapshot listener).
 *
 * Lives in `db/operations/` (not `firebase/syncService.ts`) so its import
 * graph stays free of `firebase/config` — that module transitively
 * initializes Firebase Auth at import time, which throws
 * `auth/invalid-api-key` on CI where no `.env.local` exists (the same
 * #280/#281 story documented on `applyTaskEventsBatch` in
 * `taskEventPull.ts`). Extracting this function is what makes
 * `__tests__/pullApply.test.ts` possible without a firebase mock.
 *
 * Validates the payload against the Zod schema for the collection before
 * touching Dexie. A failed parse (missing fields, wrong types, version < 1,
 * userId mismatch for user-scoped collections) logs a `Skipped` status and
 * returns without writing — corrupted remote data must never reach the
 * local source-of-truth DB.
 *
 * @param collectionName The Firestore subcollection being pulled.
 * @param remoteData The raw document data from Firestore (untrusted).
 * @param authenticatedUserId The current user's uid, for userId scope
 *   checks on user-scoped collections.
 * @returns A short status string for logging; `null` if local-wins.
 */
/**
 * Loop-guard predicate for the pull-path local-wins re-enqueue (board-integrity
 * PR-4, item 1, docs/BOARD_INTEGRITY.md): a local row that's identical to the
 * remote one it "won" against must never be re-enqueued, or every pull cycle
 * of an already-converged doc would push a redundant no-op forever.
 *
 * `resolveConflict` only ever picks 'local' when `local.version >
 * remote.version`, or (equal version and) `local.updatedAt` is strictly
 * newer — so in practice this always returns `true` on the local-wins branch.
 * It's checked explicitly (rather than leaning on that invariant) so a future
 * change to the tie-break can't silently reopen the enqueue-loop.
 *
 * Exported so it's independently unit-testable — the "identical rows never
 * enqueue" case is otherwise unreachable through `applyRemoteSubdoc` alone,
 * since an exact tie always resolves 'remote' (server authority), never
 * 'local'.
 */
export function rowsGenuinelyDiffer(local: SyncableEntity, remote: SyncableEntity): boolean {
  return local.version !== remote.version || local.updatedAt !== remote.updatedAt;
}

export async function applyRemoteSubdoc(
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
    // Read+enqueue share one transaction (mirrors the remote-wins branch's
    // rationale below): a concurrent write between the outer read and the
    // enqueue could otherwise snapshot a stale reassert payload (PR-4
    // review I1). The row is RE-READ inside the txn for the same reason.
    // Board-integrity PR-4, item 1 (docs/BOARD_INTEGRITY.md): the push path
    // conflict-checks via getDoc → setDoc with no transaction, so two devices
    // racing the same doc can land the stale write AFTER the fresh one. Before
    // this fix, "local wins" here was a silent no-op — the fresher local row
    // never re-pushed, so the divergence was permanent until some unrelated
    // edit happened to bump the row's version again. Re-enqueue an UPDATE for
    // the local row so it keeps re-asserting; `addToSyncQueue` coalesces
    // repeats and the push path re-checks conflicts itself, so a redundant
    // enqueue is at worst a harmless no-op push.
    //
    // Loop guard: only enqueue when the rows genuinely differ.
    // `resolveConflict` only returns 'local' when local.version > remote.version,
    // or (equal version and) local.updatedAt is strictly newer than remote's —
    // either way the two rows differ by construction — but check explicitly
    // rather than lean on that invariant, so an already-converged pull
    // (identical version + updatedAt) never re-enqueues and loops forever.
    if (rowsGenuinelyDiffer(localData!, validated)) {
      await db.transaction('rw', [table, db.syncQueue], async () => {
        const fresh = (await table.get(validated.id)) as SyncableEntity | undefined;
        // The row may have changed (or vanished) since the outer read —
        // re-check the guard against the FRESH row before enqueueing it.
        if (fresh && rowsGenuinelyDiffer(fresh, validated)) {
          await addToSyncQueue(collectionName, fresh.id, SyncOperationType.UPDATE, fresh, 0);
        }
      });
    }
    return null; // local-wins → re-enqueued (if it differs) so it re-asserts
  }

  // Apply the remote row to local Dexie under standard LWW. The cascade runs
  // in the same transaction so a cascade failure rolls back the upsert — the
  // pulled value is authoritative.
  //
  // Windowed Completion (docs/WINDOWED_COMPLETION.md §Shared counters
  // interaction): counting-task conflicts resolve by union-of-events (the
  // batched `taskEvents` pull recompute — see §Sync), so a pulled counting Task
  // just LWW-upserts like any other row. The Phase-4 additive-merge branch for
  // shared-counter sources was retired here (its dead code deleted in WC PR D).
  //
  // `table` is the per-collection Dexie table resolved above (e.g. `pools`,
  // `coreBoardDefaults`, `recurringBoardTemplates`, `defaultPools`, ...). It
  // must be included in the transaction's table scope explicitly — Dexie
  // throws NotFoundError for any table referenced inside a transaction that
  // wasn't declared in its scope list, which silently dropped every pulled
  // doc for collections not already named below and wedged the pull
  // watermark (the per-collection catch in `pullSync` sets `hadPullError`).
  // Dexie dedupes if `table` also happens to be one of the named tables.
  await db.transaction(
    'rw',
    [table, db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      await table.put(validated);

      // After pulling a Task or CompoundChild, cascade the board derivation
      // pass so that any board containing the changed task recomputes its
      // stats + status transitions. The cascade writes boards + sync queue
      // entries but does NOT touch the Task itself — pulled value is final.
      //
      // Cascade unconditionally (matches iOS SyncService.runPullCascade).
      // The previous `completionChanged` gate (isCompleted/currentCount diff)
      // missed compound-affecting edits — operator/threshold changes would
      // leave boards with stale stats + completedLineIds even though the
      // compound's derived state had flipped. The cascade is idempotent
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
      } else if (collectionName === 'boards') {
        // Sealed-board transport convergence (docs §Seal snapshots re-derive):
        // a pulled SEALED board doc carries whatever snapshot the sealing
        // device derived from ITS event union — which may be a stale partial
        // one (sealed offline elsewhere). Re-derive that board's frozen
        // snapshot against the LOCAL converged union, with the same
        // deterministic, no-version-bump, no-enqueue semantics as the
        // taskEvents-pull re-derive hook, inside this same pull transaction.
        // Without this, the stale snapshot sticks until (if ever) new events
        // for a placed task arrive — and since sealed re-derivation never
        // pushes, the remote copy stays stale for every future puller.
        const sealedAt = (validated as { sealedAt?: unknown }).sealedAt;
        if (typeof sealedAt === 'string' && sealedAt) {
          await reDeriveSealedBoardsByIds([validated.id]);
        }
      } else if (collectionName === 'boardTasks') {
        // Board-integrity PR-1 (docs/BOARD_INTEGRITY.md) — the boardTasks-pull
        // cascade. Before this fix, a pulled placement (live OR tombstone)
        // triggered NO board re-derivation, so a receiving device's
        // `completedLineIds` (positional!) went stale after a remote
        // rearrange, and a pulled tombstone left the removed cell counted in
        // `completedTasks` until some unrelated cascade happened to touch
        // the board. `boardId` is already known directly from the pulled
        // row (unlike the `tasks` branch, which must resolve affected
        // boards via task→board reachability, which a pulled tombstone is
        // invisible to), so this recomputes that ONE board directly.
        const boardId = (validated as { boardId?: unknown }).boardId;
        if (typeof boardId === 'string' && boardId) {
          await runBoardCascadeForBoardId(boardId);
          // Sealed re-derive mirrors the `boards` branch above: the live
          // cascade above is a no-op for a sealed board (never mutates it),
          // so re-derive its frozen snapshot from the local converged event
          // union so a pulled tombstone/rearrange still lands on the sealed
          // record instead of sticking stale forever.
          const affectedBoard = await db.boards.get(boardId);
          if (affectedBoard?.sealedAt) {
            await reDeriveSealedBoardsByIds([boardId]);
          }
        }
      }
    },
  );

  recordSyncEvent('pulled');
  if (isNew) {
    return `Pulled ${collectionName}/${validated.id} (new)`;
  }
  return `Pulled ${collectionName}/${validated.id} (remote v${validated.version} > local v${(localData as SyncableEntity).version})`;
}

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

export const COLLECTION_SCHEMAS: Record<SyncCollection, RemoteSchema> = {
  boards: BoardSchema,
  tasks: TaskSchema,
  taskSteps: TaskStepSchema,
  boardTasks: BoardTaskSchema,
  compositeTasks: CompositeTaskSchema,
  compositeNodes: CompositeNodeSchema,
  compoundChildren: CompoundChildSchema,
  recurringBoardTemplates: RecurringBoardTemplateSchema,
  defaultPools: DefaultPoolSchema,
  // Windowed Completion (docs/WINDOWED_COMPLETION.md §Sync). Row-shape Zod
  // (delta ⇄ kind, occurredAt required); the "event-owning tasks only" rule is
  // a Task-type check the row alone can't carry, so it lives at the write
  // choke points, not here. PR B sub-slice 1 wires the pull validator only —
  // no event write/read paths yet, so events sync harmlessly empty.
  taskEvents: TaskEventSchema,
  // Task Pools + Recurring Boards Rework (P1, docs/POOLS_RECURRING.md
  // §Data model). Standard per-row LWW + tombstones, same shape as every
  // other user-scoped collection above.
  pools: PoolSchema,
  coreBoardDefaults: CoreBoardDefaultSchema,
};

/**
 * Subset of syncable collections whose documents carry a top-level
 * `userId` field. For these, the pull path must reject any document
 * whose `userId` doesn't match the authenticated user — a defense
 * against a compromised peer that writes into its own path with a
 * spoofed `userId` and hopes that a future cross-user share path
 * surfaces it.
 *
 * Sourced from `@oybc/shared`'s `USER_SCOPED_SYNC_COLLECTIONS`.
 */
export const USER_SCOPED_COLLECTIONS: ReadonlySet<SyncCollection> = new Set(
  USER_SCOPED_SYNC_COLLECTIONS,
);
