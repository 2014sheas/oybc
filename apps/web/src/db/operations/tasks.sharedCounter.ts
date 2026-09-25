import { db } from '../internal';
import type {
  Task,
} from '@oybc/shared';
import {
  BoardStatus,
  SyncOperationType,
  TaskType,
  boardWindowEnd,
  isFrozenDerivedRow,
  isFrozenRowReachedByEvent,
  propagateIncrement,
  resolveTaskWindowState,
  selectLastIncrementEntry,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTasks } from './orchestration';
import { insertIncrementEventRaw, lateLogStampForBoard } from './taskEvents';
import { refreshDerivedBaselines } from './derivedCounters';

/** Resolved board reference returned by the shared-counter engine. */
export interface AffectedBoard {
  boardId: string;
  boardName: string;
}

/**
 * Shared tail of increment / decrement / undo: re-derive every LIVE linked
 * row of `sourceTaskId` from `newSourceCount`, write + enqueue each as an
 * authored update, collect the ACTIVE boards to credit, and run ONE batched
 * board cascade for the source plus those rows.
 *
 * Propagation freeze (docs/WINDOWED_COMPLETION.md §Derived-task carve-out,
 * docs/BOARD_SOURCES.md §Plan B2 notes): a window-stamped derived row whose
 * window has ended (`isFrozenDerivedRow`) gets no authored write, no enqueue
 * and no credit. The kernel resolves such rows from the root's in-window
 * events, not the latch; an increment / decrement normally stamps its event
 * `now` (after every frozen window), so it cannot change a frozen row's
 * completion and the row is left out of the cascade too — each "+1" is
 * bounded to the rows whose windows are still open. Two events CAN land
 * inside a frozen row's window (`reachOccurredAt`): an UNDO tombstones an
 * EARLIER event, and a LATE LOG from an ended board's own surface is stamped
 * at that board's `endDate` (`lateLogOccurredAt`, 2026-09-24 amendment of WC
 * Decision 1). Either DOES change that row's kernel sum: those rows
 * (`isFrozenRowReachedByEvent`) join the cascade set — cascade only, still no
 * write / enqueue — so their boards' stored stats follow the event.
 * Hub-linked rows (no `startDate`), indefinite rows and in-window rows
 * propagate as before.
 *
 * Must run inside the caller's `rw` transaction covering `tasks`,
 * `taskEvents`, `boards`, `boardTasks`, `compoundChildren` and `syncQueue`.
 *
 * @param sourceTaskId     The shared-counter root whose count just changed.
 * @param newSourceCount   The root's `currentCount` after the change.
 * @param now              The operation's ISO8601 timestamp (also the freeze clock).
 * @param reachOccurredAt  The `occurredAt` of the event this operation wrote or
 *   tombstoned (a `now` stamp reaches no frozen row, so passing it is inert).
 * @returns The live ACTIVE boards placing the source or an unfrozen linked row,
 *   read BEFORE the cascade rewrites board status.
 */
async function propagateToLinkedRows(
  sourceTaskId: string,
  newSourceCount: number,
  now: string,
  reachOccurredAt?: string,
): Promise<AffectedBoard[]> {
  // Indexed read (the `sharedCounterId` index exists since Dexie v11), then
  // drop tombstones; split off the rows whose window has ended.
  const linkedRows = await db.tasks
    .where('sharedCounterId')
    .equals(sourceTaskId)
    .filter((t) => !t.isDeleted)
    .toArray();
  const linkedTasks = linkedRows.filter((t) => !isFrozenDerivedRow(t, now));
  // Undo across the window end / late log into an ended window — cascade-only
  // reach into frozen rows whose window holds the event.
  const reachedFrozenIds =
    reachOccurredAt === undefined
      ? []
      : linkedRows.filter((t) => isFrozenRowReachedByEvent(t, reachOccurredAt, now)).map((t) => t.id);

  const propagationResults = propagateIncrement(
    { currentCount: newSourceCount },
    linkedTasks.map((t) => ({
      id: t.id,
      baseline: t.baseline,
      maxCount: t.maxCount,
      isCompleted: t.isCompleted,
    })),
  );

  for (const result of propagationResults) {
    const linkedTask = linkedTasks.find((t) => t.id === result.taskId);
    if (!linkedTask) continue;

    const wasCompleted = linkedTask.isCompleted;
    const nowCompleted = result.newIsCompleted; // one-way latch applied by propagateIncrement

    const linkedPatch: Partial<Task> = {
      currentCount: result.newCurrentCount,
      isCompleted: nowCompleted,
      completedAt: !wasCompleted && nowCompleted ? now : linkedTask.completedAt,
      updatedAt: now,
      version: (linkedTask.version ?? 0) + 1,
    };
    await db.tasks.update(result.taskId, linkedPatch);
    const savedLinked = await db.tasks.get(result.taskId);
    if (savedLinked) {
      await addToSyncQueue('tasks', result.taskId, SyncOperationType.UPDATE, savedLinked, 0);
    }
  }

  // Collect ACTIVE boards containing the source + any UNFROZEN linked task
  // BEFORE the cascade rewrites board stats/status — the "also counted" toast set.
  const allChangedTaskIds = [sourceTaskId, ...linkedTasks.map((t) => t.id)];
  const placements = await db.boardTasks
    .where('taskId').anyOf(allChangedTaskIds)
    .filter((bt) => !bt.isDeleted)
    .toArray();
  const uniqueBoardIds = [...new Set(placements.map((p) => p.boardId))];
  const boardRows = uniqueBoardIds.length > 0
    ? await db.boards.where('id').anyOf(uniqueBoardIds).toArray()
    : [];
  const affectedBoards: AffectedBoard[] = boardRows
    .filter((b) => !b.isDeleted && b.status === BoardStatus.ACTIVE)
    .map((b) => ({ boardId: b.id, boardName: b.name }));

  // ONE batched cascade: lookups + window context built once, each affected
  // board recomputed once (it reads the rows written above, same transaction).
  // Its per-board result map is not needed — credit comes from the pre-read above.
  await runBoardCascadeForTasks([...allChangedTaskIds, ...reachedFrozenIds]);

  return affectedBoards;
}

/**
 * Phase 3 — Shared Counters increment hot-path.
 *
 * Increments the source task's `currentCount` by `by` (default 1), then
 * re-derives every live linked task (tasks where `sharedCounterId === sourceTaskId`,
 * `!isDeleted`, and not a window-stamped derived row whose window has ended —
 * see {@link propagateToLinkedRows}) and runs ONE batched board derivation
 * cascade for the source AND those linked tasks — all inside one Dexie
 * transaction.
 *
 * Invariants enforced:
 *   - NO HIGH-END CLAMP on the source's `currentCount`. Overshoot is intentional.
 *   - ONE-WAY LATCH on each linked task's `isCompleted`: once `true`, stays
 *     `true` regardless of the re-derived value.
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
 * @param by - Amount to increment (default 1). Must be a positive integer.
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
  if (by <= 0 || !Number.isInteger(by)) throw new Error('incrementSharedCounter: `by` must be a positive integer');

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
      const newSourceCount = (source.currentCount ?? 0) + by;
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

      // Windowed Completion (docs §Write paths — "incrementSharedCounter …
      // becomes append-event-on-source + propagation-stamp of derived tasks").
      // Append a +by increment event on the SOURCE only (derived tasks are
      // carved out — they never own events). Raw append, no cache restamp: the
      // source's lifetime `currentCount` is already written authoritatively
      // above and equals the lifetime event sum.
      const occurredAt = await lateLogStampForBoard(boardId, now);
      await insertIncrementEventRaw(sourceTaskId, by, undefined, now, occurredAt);

      // Board Sources §Member rules (B2) — the root's event log just moved, so
      // every window-stamped derived counter hanging off it may need a new
      // `baseline`. Refreshed BEFORE the propagation read below so the derived
      // rows' displayed counts (and the board cascade at the end of this
      // transaction) are computed against the corrected boundary rather than a
      // stale one. Non-authored: `baseline` only, no version bump, no enqueue.
      // (No `events` argument: neither op has the root's log in hand, so
      // passing one would mean adding the very read it saves.)
      await refreshDerivedBaselines(sourceTaskId);

      // 3–7. Propagate to the live linked rows, collect credited boards, and
      // run ONE batched board cascade (see `propagateToLinkedRows`).
      const affectedBoards = await propagateToLinkedRows(sourceTaskId, newSourceCount, now, occurredAt);

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
 *   - ONE-WAY COMPLETION LATCH is preserved: decrement does NOT un-complete any
 *     task — once `isCompleted` is true it stays true. This is consistent with the
 *     increment engine.
 *
 * Returns the DISTINCT live ACTIVE boards containing any member task of the group,
 * and the `effectiveDelta` (positive integer = actual units removed, 0 on no-op).
 *
 * Callers must pass the SOURCE task's id (same rule as `incrementSharedCounter`).
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to decrement (default 1). Must be a positive integer.
 * @param boardId - The board whose OWN play surface made the log, if any — the
 *   same late-log stamp and sealed no-op as {@link incrementSharedCounter},
 *   plus the window-count clamp above.
 */
export async function decrementSharedCounter(
  sourceTaskId: string,
  by = 1,
  boardId?: string,
): Promise<{ affectedBoards: AffectedBoard[]; effectiveDelta: number }> {
  if (by <= 0 || !Number.isInteger(by)) throw new Error('decrementSharedCounter: `by` must be a positive integer');

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
      const newSourceCount = currentCount - eff;

      // 3. ONE-WAY LATCH: decrement does NOT un-complete.
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

      // Windowed Completion (docs §Write paths — board-context decrement
      // "append a negative-delta event … gated by windowed count > 0"). `eff`
      // is already clamped above (window count from a board, and always the
      // lifetime count), so neither sum can go negative. Raw append on the SOURCE only
      // (derived tasks are carved out); the source cache is written
      // authoritatively above.
      const occurredAt = await lateLogStampForBoard(boardId, now);
      await insertIncrementEventRaw(sourceTaskId, -eff, undefined, now, occurredAt);

      // Board Sources §Member rules (B2) — the root's event log just moved, so
      // every window-stamped derived counter hanging off it may need a new
      // `baseline`. Refreshed BEFORE the propagation read below so the derived
      // rows' displayed counts (and the board cascade at the end of this
      // transaction) are computed against the corrected boundary rather than a
      // stale one. Non-authored: `baseline` only, no version bump, no enqueue.
      // (No `events` argument: neither op has the root's log in hand, so
      // passing one would mean adding the very read it saves.)
      await refreshDerivedBaselines(sourceTaskId);

      // 4–8. Propagate (same pure helper as increment — it re-derives from the
      // new source count and ORs in the one-way latch, so decrement never
      // un-completes), collect credited boards, run ONE batched cascade.
      const affectedBoards = await propagateToLinkedRows(sourceTaskId, newSourceCount, now, occurredAt);

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
 *   5. Propagate to live linked tasks via `propagateIncrement` and run ONE
 *      batched board cascade for the source + those linked tasks, exactly
 *      like increment/decrement — plus (cascade only, no write) any FROZEN
 *      window-stamped row whose window contains the undone entry's
 *      `occurredAt`, whose kernel sum the tombstone just changed (undo across
 *      the window end; see {@link propagateToLinkedRows}).
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
      const newSourceCount = Math.max(0, currentCount - entryDelta);

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

      // Board Sources §Member rules (B2) — the root's event log just moved, so
      // every window-stamped derived counter hanging off it may need a new
      // `baseline`. Refreshed BEFORE the propagation read below so the derived
      // rows' displayed counts (and the board cascade at the end of this
      // transaction) are computed against the corrected boundary rather than a
      // stale one. Non-authored: `baseline` only, no version bump, no enqueue.
      // This op ALREADY read the root's log (step 2), so it passes it through
      // instead of re-reading — with the just-tombstoned entry marked, since
      // the in-memory copy predates step 3's write.
      await refreshDerivedBaselines(
        sourceTaskId,
        events.map((e) => (e.id === entry.id ? { ...e, isDeleted: true } : e)),
      );

      // 6–8. Propagate to the live linked rows exactly like
      // increment/decrement, then run ONE batched board cascade — which also
      // reaches (cascade-only) frozen rows whose window holds the undone event.
      const affectedBoards = await propagateToLinkedRows(
        sourceTaskId,
        newSourceCount,
        now,
        entry.occurredAt,
      );

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
 * @param amount A positive integer.
 */
export async function setCounterDefaultLogAmount(
  sourceTaskId: string,
  amount: number,
): Promise<void> {
  if (!Number.isInteger(amount) || amount <= 0) {
    throw new Error('setCounterDefaultLogAmount: amount must be a positive integer');
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
