import {
  TaskEventSchema,
  isEventOwningTask,
  resolveConflict,
  type SyncableEntity,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../internal';
import { runBoardCascadeForTasks } from './orchestration';
import { recomputeTaskCachesFromPull } from './taskEvents';
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

      // 4. ONE derivation pass per affected board (batched over the task set).
      if (cascadeTaskIds.size > 0) {
        await runBoardCascadeForTasks(cascadeTaskIds);
      }
    },
  );

  for (let i = 0; i < pulled; i += 1) recordSyncEvent('pulled');
  return { pulled, details };
}
