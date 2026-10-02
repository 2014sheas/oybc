import {
  SyncOperationType,
  computeWindowBaseline,
  planLinkedCounterWindowHeal,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { runBoardCascadeForTasks } from './orchestration';
import { refreshDerivedBaselines, withWindowStampedDerived } from './derivedCounters';
import { materializeWindowCopy } from './linkedCounterPlacement';
import { addToSyncQueue, stampTransactionSyncOwner } from './syncQueue';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { currentTimestamp } from '../utils';

/**
 * Windowed linked counters — the one-time (idempotent) heal of pre-rule
 * hub-linked counters (owner rule 2026-10-01: a counting square on a board
 * accounts ONLY for the counter's logs inside that board's window).
 *
 * "Hub-linked" = a task with `sharedCounterId` that is not
 * `isWindowStampedDerived`. Before the rule a board could place such a row
 * (made by the retired "From a board…" picker / tap=Link), and its square
 * read the root's lifetime latch — so a log made for a different board's
 * window moved it (the incident: a +5 on an ended September board credited a
 * closed June board). The pure plan (`planLinkedCounterWindowHeal`, shared
 * with iOS, vector-pinned) decides which rows get stamped in place with
 * their first board's window and which further placements get a fresh
 * deterministic per-board copy. This file applies it:
 *
 *   - **Stamp** — `timeframe` / `startDate` / `endDate` + `createdInWizard`
 *     (the third mark `isWindowStampedDerived` needs), `version + 1`, UPDATE
 *     enqueue. Authored with deterministic content, so every device converges
 *     on the same row (two devices healing concurrently write equal values).
 *   - **Copy** — `materializeWindowCopy` (insert / revive the deterministic
 *     `derivedTaskId(board, root)` row + enqueue), then the placement
 *     (`boardTask`) is repointed at it (`version + 1`, UPDATE enqueue).
 *
 * Afterwards, inside the same transaction: `refreshDerivedBaselines` for every
 * touched root (non-authored cache), the live board cascade for the reached
 * boards, and the sealed re-derivation (a sealed board's cells become a pure
 * function of in-window root events — June may re-derive to a different count
 * than it showed before; that IS the rule).
 *
 * Idempotent + self-limiting: once applied, stamped rows are
 * window-stamped and repointed placements no longer place the source, so the
 * next run plans nothing and returns `{0, 0}` without opening any writes.
 * Safe to call after every clean pull and from the Dexie v18 upgrade.
 *
 * Documented residuals (the source placement is then left as-is; the kernel
 * fallback still renders it windowed, and a later sweep re-plans it):
 *   - the board ALREADY holds a live placement of the copy id (repointing would
 *     duplicate a square) — the copy is skipped entirely;
 *   - the deterministic copy id is TOMBSTONED — it is NOT revived here (the
 *     revive could lose to a higher-version remote tombstone and orphan the
 *     repointed placement). The placement choke points still revive, since
 *     there it is user-authored intent.
 *
 * Swift twin: `AppDatabase+LinkedCounterWindowHeal.swift`.
 *
 * @param userId The owning user's uid (scope guard + sync owner).
 * @returns How many rows were stamped in place and how many copies minted.
 */
export async function healLinkedCounterWindows(
  userId: string,
): Promise<{ stamped: number; copied: number }> {
  let stamped = 0;
  let copied = 0;

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      stampTransactionSyncOwner(userId);
      const [tasks, boardTasks, boards, compoundChildren] = await Promise.all([
        db.tasks.toArray(),
        db.boardTasks.toArray(),
        db.boards.toArray(),
        db.compoundChildren.toArray(),
      ]);
      const ownTasks = tasks.filter((t) => t.userId === userId);
      const ownBoards = boards.filter((b) => b.userId === userId);
      const plan = planLinkedCounterWindowHeal({
        tasks: ownTasks,
        boardTasks,
        boards: ownBoards,
        compoundChildren,
      });
      if (plan.stamps.length === 0 && plan.copies.length === 0) return;

      const now = currentTimestamp();
      const taskById = new Map<string, Task>(ownTasks.map((t) => [t.id, t]));
      const touchedRoots = new Set<string>();
      const touchedIds = new Set<string>();

      for (const stamp of plan.stamps) {
        const task = taskById.get(stamp.taskId);
        if (!task) continue;
        // Baseline BEFORE the put/enqueue so the queued payload is not stale
        // (iOS parity); `refreshDerivedBaselines` below stays as the cache refresh.
        const rootEvents = task.sharedCounterId
          ? await db.taskEvents.where('taskId').equals(task.sharedCounterId).toArray()
          : [];
        const baseline = task.sharedCounterId
          ? computeWindowBaseline(task.sharedCounterId, rootEvents, stamp.startDate)
          : task.baseline;
        const next: Task = {
          ...task,
          ...(baseline !== undefined ? { baseline } : {}),
          timeframe: stamp.timeframe,
          startDate: stamp.startDate,
          createdInWizard: true,
          updatedAt: now,
          version: (task.version ?? 0) + 1,
        };
        if (stamp.endDate == null) delete (next as { endDate?: string }).endDate;
        else next.endDate = stamp.endDate;
        await db.tasks.put(next);
        await addToSyncQueue('tasks', next.id, SyncOperationType.UPDATE, next, 0, { ownerUid: userId });
        if (task.sharedCounterId) touchedRoots.add(task.sharedCounterId);
        touchedIds.add(next.id);
        stamped += 1;
      }

      const btById = new Map<string, BoardTask>(boardTasks.map((b) => [b.id, b]));
      const livePlacedTaskIdsByBoard = new Map<string, Set<string>>();
      for (const b of boardTasks) {
        if (b.isDeleted) continue;
        let ids = livePlacedTaskIdsByBoard.get(b.boardId);
        if (!ids) livePlacedTaskIdsByBoard.set(b.boardId, (ids = new Set()));
        ids.add(b.taskId);
      }

      for (const copy of plan.copies) {
        const source = taskById.get(copy.sourceTaskId);
        const bt = btById.get(copy.boardTaskId);
        if (!source || !bt) continue;
        // Never duplicate a square: the board already shows `copy.id`.
        if (livePlacedTaskIdsByBoard.get(copy.boardId)?.has(copy.id)) continue;
        const row = await materializeWindowCopy(copy, source, userId, now, {
          reviveTombstoned: false,
        });
        if (!row) continue;
        const repointed: BoardTask = {
          ...bt,
          taskId: copy.id,
          updatedAt: now,
          version: (bt.version ?? 0) + 1,
        };
        await db.boardTasks.put(repointed);
        await addToSyncQueue('boardTasks', repointed.id, SyncOperationType.UPDATE, repointed, 0, {
          ownerUid: userId,
        });
        touchedRoots.add(copy.rootTaskId);
        touchedIds.add(copy.id);
        touchedIds.add(copy.sourceTaskId);
        livePlacedTaskIdsByBoard.get(copy.boardId)?.delete(copy.sourceTaskId);
        let placed = livePlacedTaskIdsByBoard.get(copy.boardId);
        if (!placed) livePlacedTaskIdsByBoard.set(copy.boardId, (placed = new Set()));
        placed.add(copy.id);
        copied += 1;
      }

      for (const root of touchedRoots) await refreshDerivedBaselines(root);
      const cascadeIds = await withWindowStampedDerived(new Set([...touchedIds, ...touchedRoots]));
      await runBoardCascadeForTasks(cascadeIds);
      await reDeriveSealedBoardsForTasks(cascadeIds);
    },
  );

  return { stamped, copied };
}
