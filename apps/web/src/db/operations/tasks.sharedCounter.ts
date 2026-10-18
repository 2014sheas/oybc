import { db } from '../internal';
import type {
  Task,
} from '@oybc/shared';
import {
  SyncOperationType,
  TaskType,
  boardWindowEnd,
  isEventSealImmune,
  isQuantizedCount,
  quantizeCount,
  resolveTaskWindowState,
  selectLastIncrementEntry,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTasks } from './orchestration';
import { insertIncrementEventRaw, lateLogStampForBoard, getSealImmuneWindowsForTask } from './taskEvents';
import { loadPlacementReach } from './placementReach';
import { isBoardCreditable } from '../../utils/boardDisplayUtils';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { resolveAffectedBoardIds, refreshWatchersForBoards } from './boardLifecycle';

/** Resolved board reference returned by the shared-counter engine. */
export interface AffectedBoard {
  boardId: string;
  boardName: string;
}

/**
 * Shared tail of increment / decrement / undo / late log: the root's event
 * log just moved. Every live linked row resolves from those events on its
 * board (TASK_WINDOW_REWORK slice 5 — nothing is written to a linked row), so
 * this collects the ACTIVE boards to credit, runs ONE batched board cascade
 * for the root and its linked rows, and — for an event stamped away from
 * `now` (a late log at an ended board's `endDate`) — re-derives the sealed
 * boards whose window may hold it and refreshes their watchers.
 *
 * Must run inside the caller's `rw` transaction covering `tasks`,
 * `taskEvents`, `boards`, `boardTasks`, `compoundChildren` and `syncQueue`.
 *
 * @param sourceTaskId     The shared-counter root whose events just moved.
 * @param now              The operation's ISO8601 timestamp.
 * @param reachOccurredAt  The `occurredAt` of the event this operation wrote
 *   or tombstoned, when known.
 * @returns The live ACTIVE boards placing the root or a linked row, read
 *   BEFORE the cascade rewrites board status.
 */
export async function runCounterRootCascade(
  sourceTaskId: string,
  now: string,
  reachOccurredAt?: string,
): Promise<AffectedBoard[]> {
  const reach = await loadPlacementReach([sourceTaskId]);
  const changedIds = [...reach.taskIds];

  // The "also counted" toast set: boards placing the root or a linked row
  // directly, read BEFORE the cascade rewrites board stats/status.
  const directBoardIds = new Set(
    reach.placements.filter((p) => p.viaCompoundId == null).map((p) => p.boardTask.boardId),
  );
  const boardRows = directBoardIds.size > 0 ? await db.boards.where('id').anyOf([...directBoardIds]).toArray() : [];
  const affectedBoards: AffectedBoard[] = boardRows
    // A sealed (Closed) or ended board cannot change, so it is never credited.
    .filter((b) => isBoardCreditable(b, new Date(now)))
    .map((b) => ({ boardId: b.id, boardName: b.name }));

  await runBoardCascadeForTasks(changedIds);

  // One late-log tail (TASK_WINDOW_REWORK slice 0): an event stamped at an
  // ended board's `endDate` can land inside a SEALED containing board's
  // window; the live cascade skips sealed boards (iOS twin:
  // `runSharedCounterCascade(lateLogStamp:)`).
  if (reachOccurredAt != null && reachOccurredAt !== now) {
    await reDeriveSealedBoardsForTasks(changedIds);
    if (reach.boardIds.size > 0) await refreshWatchersForBoards(reach.boardIds);
  }

  return affectedBoards;
}

/**
 * Phase 3 — Shared Counters increment hot-path.
 *
 * Increments the source task's `currentCount` by `by` (default 1), appends
 * the increment event, and runs ONE batched board derivation cascade for the
 * source and its live linked rows (which resolve from the source's events —
 * see {@link runCounterRootCascade}) — all inside one Dexie transaction. An
 * increment writes the root alone: no linked-row write, no sync item for a copy.
 *
 * Invariants enforced:
 *   - NO HIGH-END CLAMP on the source's `currentCount`. Overshoot is intentional.
 *   - All writes (task rows + board cascade + sync entries) are atomic. A
 *     partial failure rolls back everything.
 *
 * Callers must NOT call this for a linked (derived) task — pass the source
 * task's id. A linked task's `sharedCounterId` points at the source; tapping
 * a linked task on a board should call `incrementSharedCounter` with the
 * source id, not the linked id.
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to increment (default 1). Must be a positive 2dp number.
 * @param boardId - The board whose OWN play surface made the log, if any. When
 *   that board's window has ended, the event is stamped at its `endDate`
 *   (see `lateLogStampForBoard`); omitted (hub / counter detail /
 *   library) → stamped `now`. A SEALED board is a full no-op (no event, no
 *   write) — a sealed board authors no event.
 */
export async function incrementSharedCounter(
  sourceTaskId: string,
  by = 1,
  boardId?: string,
): Promise<{ affectedBoards: AffectedBoard[] }> {
  if (by <= 0 || !isQuantizedCount(by)) throw new Error('incrementSharedCounter: `by` must be a positive 2dp number');

  return db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return { affectedBoards: [] };
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `incrementSharedCounter: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      // Source must NOT be a linked task itself (it must be the accumulator).
      if (source.sharedCounterId != null) {
        throw new Error(
          `incrementSharedCounter: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // Final-review F5: a SEALED board authors no event (play is locked; its
      // record is permanent). Mirrors `handleTaskCompletion`'s sealed no-op.
      const logBoard = boardId !== undefined ? await db.boards.get(boardId) : undefined;
      if (logBoard?.sealedAt) return { affectedBoards: [] };

      // 2. Compute new source count — NO high-end clamp (overshoot is intentional).
      // A goal-less source (P5 hub-born counter, `maxCount == null`) never
      // auto-completes — the one-way latch below only fires once a maxCount exists.
      const newSourceCount = quantizeCount((source.currentCount ?? 0) + by);
      const sourceMaxCount = source.maxCount;

      // isCompleted: one-way latch. Source uses a simpler logic than derived tasks:
      // the source tracks its own maxCount independently. We apply the latch here too.
      const sourceWasCompleted = source.isCompleted;
      const sourceNowCompleted =
        sourceWasCompleted || (sourceMaxCount != null && newSourceCount >= sourceMaxCount);

      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        isCompleted: sourceNowCompleted,
        completedAt: !sourceWasCompleted && sourceNowCompleted ? now : source.completedAt,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      // Enqueue sync for the source task.
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, savedSource, 0);
      }

      // Windowed Completion: append a +by increment event on the SOURCE only
      // (linked rows never own events). Raw append, no cache restamp: the
      // source's lifetime `currentCount` is already written authoritatively
      // above and equals the lifetime event sum.
      const occurredAt = await lateLogStampForBoard(boardId, now);
      await insertIncrementEventRaw(sourceTaskId, by, undefined, now, occurredAt);

      // 3. Collect credited boards and run ONE batched board cascade.
      const affectedBoards = await runCounterRootCascade(sourceTaskId, now, occurredAt);

      return { affectedBoards };
    },
  );
}
/**
 * Decrement the shared-counter accumulator for a given source task id.
 *
 * Mirrors `incrementSharedCounter` with the following differences:
 *   - `eff = min(by, source.currentCount)` — cannot go below 0. With a
 *     `boardId`, `eff` is further clamped to that board's WINDOW count
 *     (`[startDate, endDate]`) — the count its cell shows.
 *   - If `eff === 0` → no-op, returns `{ affectedBoards: [], effectiveDelta: 0 }`.
 *   - The source's ONE-WAY COMPLETION LATCH is preserved: decrement does NOT
 *     un-complete it (a lifetime cache; boards evaluate events).
 *
 * Returns the DISTINCT live ACTIVE boards containing any member task of the group,
 * and the `effectiveDelta` (positive 2dp number = actual units removed, 0 on no-op).
 *
 * Callers must pass the SOURCE task's id (same rule as `incrementSharedCounter`).
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to decrement (default 1). Must be a positive 2dp number.
 * @param boardId - The board whose OWN play surface made the log, if any — the
 *   same late-log stamp and sealed no-op as {@link incrementSharedCounter},
 *   plus the window-count clamp above.
 */
export async function decrementSharedCounter(
  sourceTaskId: string,
  by = 1,
  boardId?: string,
): Promise<{ affectedBoards: AffectedBoard[]; effectiveDelta: number }> {
  if (by <= 0 || !isQuantizedCount(by)) throw new Error('decrementSharedCounter: `by` must be a positive 2dp number');

  return db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return { affectedBoards: [], effectiveDelta: 0 };
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `decrementSharedCounter: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      if (source.sharedCounterId != null) {
        throw new Error(
          `decrementSharedCounter: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // Final-review F5: a SEALED board authors no event (play is locked; its
      // record is permanent). Mirrors `handleTaskCompletion`'s sealed no-op.
      const logBoard = boardId !== undefined ? await db.boards.get(boardId) : undefined;
      if (logBoard?.sealedAt) return { affectedBoards: [], effectiveDelta: 0 };

      // 2. Compute effective delta — clamp to what the source actually holds.
      // Final-review F6: from a board, the clamp is that board's WINDOW count
      // (`[startDate, endDate]`, what its cell shows) — the negative event is
      // stamped inside that window, so taking more than the window holds would
      // bleed into overlapping windows (e.g. the monthly containing that day).
      // Still capped by the lifetime count so the lifetime sum stays >= 0.
      const currentCount = source.currentCount ?? 0;
      let available = currentCount;
      if (logBoard) {
        const events = await db.taskEvents.where('taskId').equals(sourceTaskId).toArray();
        const { count: windowCount } = resolveTaskWindowState(
          source,
          events.filter((e) => !e.isDeleted),
          logBoard.startDate,
          boardWindowEnd(logBoard),
        );
        available = Math.min(currentCount, Math.max(0, windowCount));
      }
      const eff = Math.min(by, available);
      if (eff === 0) return { affectedBoards: [], effectiveDelta: 0 };

      // A goal-less source (P5 hub-born counter, `maxCount == null`) never
      // auto-completes — the one-way latch below only fires once a maxCount exists.
      const newSourceCount = quantizeCount(currentCount - eff);

      // 3. ONE-WAY LATCH: decrement does NOT un-complete — and never
      //    completes either (slice 0, iOS parity: a decrement cannot be the
      //    log that reaches a goal; the latch is left exactly as it was).
      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, savedSource, 0);
      }

      // Windowed Completion (docs §Write paths — board-context decrement
      // "append a negative-delta event … gated by windowed count > 0"). `eff`
      // is already clamped above (window count from a board, and always the
      // lifetime count), so neither sum can go negative. Raw append on the SOURCE only
      // (derived tasks are carved out); the source cache is written
      // authoritatively above.
      const occurredAt = await lateLogStampForBoard(boardId, now);
      await insertIncrementEventRaw(sourceTaskId, -eff, undefined, now, occurredAt);

      // 4. Collect credited boards and run ONE batched cascade.
      const affectedBoards = await runCounterRootCascade(sourceTaskId, now, occurredAt);

      return { affectedBoards, effectiveDelta: eff };
    },
  );
}

/**
 * Result of {@link undoLastCounterLog}.
 */
export interface UndoCounterLogResult {
  /** Distinct live ACTIVE boards containing any changed member task. */
  affectedBoards: AffectedBoard[];
  /**
   * Absolute amount reversed (the tombstoned event's `|delta|`), or `0`
   * when there was nothing to undo (no live increment event on the
   * source).
   */
  undoneAmount: number;
}

/**
 * Reverses the most recent counter log on a source task (R2 Counters UX
 * refresh — the "Logged +N · Undo" toast).
 *
 * `incrementSharedCounter`/`decrementSharedCounter` append their event via
 * `insertIncrementEventRaw`, which deliberately SKIPS the cache restamp
 * (`stampTaskCachesAuthored`) — the source's `currentCount` is already
 * written authoritatively by their own arithmetic, and a restamp would
 * double-bump `version`. That means reversing a logged entry is NOT a bare
 * tombstone: this function must also correct `currentCount` itself and
 * re-run the cross-board cascade, mirroring `decrementSharedCounter`'s
 * write shape but keyed to the specific event being undone (whose `delta`
 * may itself be negative, if the entry being undone was a decrement) rather
 * than a fresh negative event.
 *
 * Sequence:
 *   1. `selectLastIncrementEntry` (pure, `@oybc/shared`) picks the most
 *      recent non-deleted, non-seed increment event on the source.
 *   2. Tombstone that event (`isDeleted`, bump version, enqueue DELETE).
 *   3. `newCurrentCount = max(0, currentCount - entry.delta)` — subtracting
 *      a positive delta reverses a log; subtracting a negative delta (an
 *      undone decrement) adds the amount back. The floor is defensive only:
 *      undoing the most-recent entry against the count it produced never
 *      goes negative in practice.
 *   4. ONE-WAY COMPLETION LATCH preserved, matching increment/decrement:
 *      undo does not un-complete an already-completed source. (Undo is a
 *      narrow reversal of the ledger entry, not a full re-derivation.)
 *   5. Run ONE batched board cascade for the source + its live linked rows,
 *      exactly like increment/decrement ({@link runCounterRootCascade}).
 *
 * No-op (returns `{ affectedBoards: [], undoneAmount: 0 }`) when the source
 * is missing/deleted or has no undoable entry — callers should treat that
 * as "Undo is no longer available" (e.g. the toast already dismissed after
 * a second log elsewhere).
 *
 * @param sourceTaskId The id of the source (template) task whose last log
 *   entry to reverse. Must NOT be a linked/derived task.
 */
export async function undoLastCounterLog(sourceTaskId: string): Promise<UndoCounterLogResult> {
  return db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return { affectedBoards: [], undoneAmount: 0 };
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `undoLastCounterLog: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      if (source.sharedCounterId != null) {
        throw new Error(
          `undoLastCounterLog: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // 2. Find the entry to reverse.
      const events = await db.taskEvents.where('taskId').equals(sourceTaskId).toArray();
      const entry = selectLastIncrementEntry(events, sourceTaskId);
      if (!entry) return { affectedBoards: [], undoneAmount: 0 };

      // Board Edit redesign slice 4 (D9/D10) — refuse to tombstone a
      // seal-immune entry: once a containing board has sealed AFTER this
      // entry was created, it is frozen history (unless it is itself a late
      // log on a closed board, which `isEventSealImmune` already excludes).
      const immuneWindows = await getSealImmuneWindowsForTask(sourceTaskId);
      if (isEventSealImmune(entry, immuneWindows)) {
        return { affectedBoards: [], undoneAmount: 0 };
      }

      // 3. Tombstone it.
      const tombstonedVersion = (entry.version ?? 1) + 1;
      await db.taskEvents.update(entry.id, {
        isDeleted: true,
        deletedAt: now,
        updatedAt: now,
        version: tombstonedVersion,
      });
      const savedEvent = await db.taskEvents.get(entry.id);
      if (savedEvent) {
        await addToSyncQueue('taskEvents', entry.id, SyncOperationType.DELETE, savedEvent, 0);
      }

      // 4. Correct the source's currentCount by subtracting the reversed
      //    entry's delta (raw-append bypassed the cache restamp — see docstring).
      //    `delta` is optional on `TaskEvent` only because it's forbidden on
      //    `completion`-kind events; `selectLastIncrementEntry` only ever
      //    returns `increment`-kind events, which always carry one — the
      //    `?? 0` is a defensive fallback, never expected to fire.
      const entryDelta = entry.delta ?? 0;
      const currentCount = source.currentCount ?? 0;
      const newSourceCount = Math.max(0, quantizeCount(currentCount - entryDelta));

      // 5. ONE-WAY LATCH: undo does not un-complete (mirrors increment/decrement).
      const sourceWasCompleted = source.isCompleted;
      const sourceNowCompleted =
        sourceWasCompleted || (source.maxCount != null && newSourceCount >= source.maxCount);

      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        isCompleted: sourceNowCompleted,
        completedAt: !sourceWasCompleted && sourceNowCompleted ? now : source.completedAt,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, savedSource, 0);
      }

      // 6. Collect credited boards and run ONE batched board cascade.
      const affectedBoards = await runCounterRootCascade(sourceTaskId, now, entry.occurredAt);

      // Board Edit redesign slice 4 (D9) — the undone entry may also fall
      // inside a SEALED containing board's frozen window (e.g. undoing a
      // Tuesday log that a sealed weekly also counted): re-derive every
      // sealed board placing the source or a linked row, then refresh any
      // achievement watcher of whatever just changed.
      await reDeriveSealedBoardsForTasks([sourceTaskId]);
      const watcherSeedIds = await resolveAffectedBoardIds([sourceTaskId]);
      if (watcherSeedIds.size > 0) await refreshWatchersForBoards(watcherSeedIds);

      return { affectedBoards, undoneAmount: Math.abs(entryDelta) };
    },
  );
}

/**
 * Persists the amount a user just logged with as the counter's new default
 * (R2 Counters UX refresh — "Default amount = last-used per counter,
 * persisted"). A plain task-field update: version bump + sync enqueue, no
 * event/cascade side effects (this never changes `currentCount`).
 *
 * No-op when the amount already matches the stored default (avoids a
 * needless version bump / sync entry on every repeat log with the same
 * amount).
 *
 * @param sourceTaskId The counter's source task id. Must NOT be a
 *   linked/derived task — `defaultLogAmount` is only meaningful on the
 *   accumulator.
 * @param amount A positive 2dp number.
 */
export async function setCounterDefaultLogAmount(
  sourceTaskId: string,
  amount: number,
): Promise<void> {
  if (!isQuantizedCount(amount) || amount <= 0) {
    throw new Error('setCounterDefaultLogAmount: amount must be a positive 2dp number');
  }

  return db.transaction('rw', [db.tasks, db.syncQueue], async () => {
    const source = await db.tasks.get(sourceTaskId);
    if (!source || source.isDeleted) return;
    if (source.type !== TaskType.COUNTING) {
      throw new Error(
        `setCounterDefaultLogAmount: task ${sourceTaskId} is not a COUNTING task`,
      );
    }
    if (source.sharedCounterId != null) {
      throw new Error(
        `setCounterDefaultLogAmount: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
      );
    }
    if (source.defaultLogAmount === amount) return;

    const now = currentTimestamp();
    await db.tasks.update(sourceTaskId, {
      defaultLogAmount: amount,
      updatedAt: now,
      version: (source.version ?? 0) + 1,
    });
    const updated = await db.tasks.get(sourceTaskId);
    if (updated) {
      await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, updated, 0);
    }
  });
}
