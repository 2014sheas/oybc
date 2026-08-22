import {
  TaskEventSchema,
  SyncOperationType,
  buildBackfillTaskEvent,
  isEventOwningTask,
  resolveConflict,
  type SyncableEntity,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../internal';
import { runBoardCascadeForTasks } from './orchestration';
import { recomputeTaskCachesFromPull } from './taskEvents';
import { addToSyncQueue } from './syncQueue';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { recordSyncEvent } from '../../firebase/syncStatus';

/**
 * Batched pull-path handler for the `taskEvents` collection
 * (docs/WINDOWED_COMPLETION.md §Sync — "Batched pull-path recompute"). Per-row
 * recompute × the full-workspace cascade would make a fresh device's initial
 * sync of 10–20k events quadratic-ish; instead we apply ALL pulled event rows
 * first, then recompute each affected event-owning task's caches ONCE and run
 * ONE derivation pass per affected board — all inside a single transaction (the
 * atomic pull-path invariant).
 *
 * Pull ordering (docs §Sync): a `taskEvent` can arrive before its `Task` row.
 * Such events are still upserted as rows but SKIPPED by the recompute — the
 * safety-net pull picks them up once the Task lands.
 *
 * Lives in `db/operations/` (not `firebase/syncService.ts`) so its import
 * graph stays free of `firebase/config` — that module transitively
 * initializes Firebase Auth at import time, which throws
 * `auth/invalid-api-key` on CI where no `.env.local` exists. `syncService.ts`
 * keeps a thin caller that imports this function (learned the hard way: PR
 * #280/#281's CI failure, repeated for this same batched-pull recompute in
 * PR #318's web lane — see `db/operations/__tests__/taskEventPull.test.ts`
 * and `pages/createHub/wizardTimeframeSeed.ts`'s header for the same story).
 * `recordSyncEvent` is imported from `firebase/syncStatus`, which is itself
 * import-free (no firebase SDK touch) despite living under `firebase/`.
 *
 * @param userId   The authenticated user's uid (for the userId scope check).
 * @param rawDocs  The untrusted raw event documents from Firestore.
 * @returns Pulled-row count + per-row skip/status details.
 */
export async function applyTaskEventsBatch(
  userId: string,
  rawDocs: unknown[],
): Promise<{ pulled: number; details: string[] }> {
  const details: string[] = [];

  // 1. Validate + userId-scope every incoming row (no DB access yet).
  const valid: TaskEvent[] = [];
  for (const raw of rawDocs) {
    const parsed = TaskEventSchema.safeParse(raw);
    if (!parsed.success) {
      const reason = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join(', ');
      const id =
        typeof (raw as { id?: unknown })?.id === 'string' ? (raw as { id: string }).id : '?';
      details.push(`Skipped malformed taskEvents/${id}: ${reason}`);
      continue;
    }
    const ev = parsed.data as TaskEvent;
    if (ev.userId !== userId) {
      details.push(`Skipped taskEvents/${ev.id}: userId mismatch`);
      continue;
    }
    valid.push(ev);
  }
  if (valid.length === 0) return { pulled: 0, details };

  let pulled = 0;
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      // 2. LWW-upsert each event row (union by id; tombstone = undo). Collect
      //    the affected task ids.
      const affectedTaskIds = new Set<string>();
      for (const ev of valid) {
        const local = (await db.taskEvents.get(ev.id)) as SyncableEntity | undefined;
        const remoteWins =
          !local || resolveConflict(local, ev as unknown as SyncableEntity).winner === 'remote';
        if (!remoteWins) continue;
        await db.taskEvents.put(ev);
        affectedTaskIds.add(ev.taskId);
        pulled += 1;
      }

      // 3. Recompute caches ONCE per affected event-owning task that exists
      //    locally (recompute is a non-authored write — no version bump, no
      //    sync enqueue). Events whose task isn't local yet are skipped-and-
      //    deferred (safety-net retry).
      const cascadeTaskIds = new Set<string>();
      for (const taskId of affectedTaskIds) {
        const task = await db.tasks.get(taskId);
        if (!task || !isEventOwningTask(task)) continue;
        await recomputeTaskCachesFromPull(taskId);
        cascadeTaskIds.add(taskId);
      }

      // 4. ONE derivation pass per affected LIVE board (batched over the task
      //    set). Sealed boards are excluded here (fan-out exclusion).
      if (cascadeTaskIds.size > 0) {
        await runBoardCascadeForTasks(cascadeTaskIds);
      }

      // 5. Seal re-derivation (docs §Seal snapshots re-derive from the event
      //    union): late pre-seal events for a placed task deterministically
      //    re-derive any affected SEALED board's frozen snapshot — the only
      //    sanctioned mutation of a sealed record. Uses `affectedTaskIds`
      //    (not `cascadeTaskIds`), because a sealed board can be affected by
      //    an event whose Task isn't locally present yet for cache recompute
      //    but IS placed on the sealed board. Local-only, inside this txn.
      if (affectedTaskIds.size > 0) {
        await reDeriveSealedBoardsForTasks(affectedTaskIds);
      }
    },
  );

  for (let i = 0; i < pulled; i += 1) recordSyncEvent('pulled');
  return { pulled, details };
}

/**
 * Heal-on-pull (docs/WINDOWED_COMPLETION.md §Heal-on-pull). Repairs the
 * fresh-install backfill gap: the v13 event backfill runs as a Dexie migration,
 * so on a fresh DB it fires on empty data and mints nothing; the sync pull then
 * brings tasks whose `isCompleted` is true but whose backing `task_event` isn't
 * in Firestore. Those completions render incomplete on every windowed surface
 * (the derivation never falls back to the lifetime cache when a windowContext is
 * present). `recomputeTaskCachesFromPull` only touches tasks whose *events* were
 * in a pull, so a zero-event task KEEPS its pulled `isCompleted` cache — which is
 * exactly the signal this sweep heals from.
 *
 * For every event-owning task (NORMAL / plain COUNTING) that is lifetime-complete
 * (`isCompleted` or `currentCount > 0`) but has NO live event, it mints the event
 * via the shared `buildBackfillTaskEvent` (deterministic id → converges with the
 * migration + iOS + peers; idempotent), ENQUEUES a CREATE (so the repair
 * propagates — the one authored write in the pull neighborhood), then runs the
 * same recompute + board cascade + sealed re-derive the event-pull path uses.
 *
 * Idempotent + self-limiting: once healed, a task HAS a live event, so it's
 * skipped on every subsequent run (the candidate set shrinks to empty). Safe to
 * call after each pull cycle; cheap once the initial backlog is cleared.
 *
 * Carve-outs (derived counters / compound / achievement) return `null` from
 * `buildBackfillTaskEvent` and are skipped — they don't own events.
 *
 * @param userId The authenticated user's uid (scope guard, mirrors the batch).
 * @returns The number of completion/increment events minted this pass.
 */
export async function healMissingCompletionEvents(userId: string): Promise<number> {
  let minted = 0;

  // Everything — the candidate scan AND the writes — runs in ONE transaction so
  // the whole sweep is atomic against concurrent local writes (matches the iOS
  // twin; the atomic pull-path invariant, CLAUDE.md §Important Patterns). Once
  // healed the candidate set is empty, so the in-txn full-scan is near-free.
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      const [tasks, allEvents] = await Promise.all([db.tasks.toArray(), db.taskEvents.toArray()]);
      const hasLiveEvent = new Set<string>();
      for (const e of allEvents) if (!e.isDeleted) hasLiveEvent.add(e.taskId);

      const healedTaskIds = new Set<string>();
      for (const task of tasks) {
        if (task.userId !== userId) continue;
        if (task.isDeleted || !isEventOwningTask(task)) continue;
        if (hasLiveEvent.has(task.id)) continue; // live events → they're authoritative
        const complete = task.isCompleted === true || (task.currentCount ?? 0) > 0;
        if (!complete) continue;
        const ev = buildBackfillTaskEvent(task); // null for carve-outs / genuinely-incomplete
        if (!ev) continue;

        // Respect LWW against any existing local row with this deterministic id —
        // in particular a TOMBSTONE from an explicit undo (not in `hasLiveEvent`
        // because it's soft-deleted). Blind-overwriting it would resurrect undone
        // state AND drive a wrong board cascade before self-correcting on the next
        // round-trip. Treat the mint as "remote" (same as applyTaskEventsBatch):
        // only proceed if it would actually win.
        const existing = (await db.taskEvents.get(ev.id)) as SyncableEntity | undefined;
        if (existing && resolveConflict(existing, ev as unknown as SyncableEntity).winner !== 'remote') {
          continue;
        }

        // Deterministic id → put is an upsert; a concurrent real event with the
        // same id just wins by LWW. Enqueue CREATE so the repair reaches Firestore
        // and every peer converges.
        await db.taskEvents.put(ev);
        await addToSyncQueue('taskEvents', ev.id, SyncOperationType.CREATE, ev);
        healedTaskIds.add(ev.taskId);
        minted += 1;
      }
      if (healedTaskIds.size === 0) return;

      // Recompute caches from the now-present events, then one board cascade +
      // sealed re-derive over the healed set — same shape as applyTaskEventsBatch.
      for (const taskId of healedTaskIds) await recomputeTaskCachesFromPull(taskId);
      await runBoardCascadeForTasks(healedTaskIds);
      await reDeriveSealedBoardsForTasks(healedTaskIds);
    },
  );

  for (let i = 0; i < minted; i += 1) recordSyncEvent('pulled');
  return minted;
}
