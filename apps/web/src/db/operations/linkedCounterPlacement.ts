import {
  buildDerivedRows,
  computeWindowBaseline,
  derivedTaskId,
  isWindowStampedForBoard,
  windowStampedCopyDraft,
  type Board,
  type LinkedCounterWindowCopy,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { refreshDerivedBaselines, writeMintedRow } from './derivedCounters';

/**
 * linkedCounterPlacement.ts — windowed linked counters, web half
 * (owner rule 2026-10-01: a counting square on a board accounts ONLY for the
 * counter's logs inside that board's window).
 *
 * "Hub-linked" below means a task with `sharedCounterId` that is not
 * `isWindowStampedDerived`. That kind is retired for anything placed on a
 * board: every linked placement is a per-board window-stamped row. This file
 * holds the two write halves both the placement choke points
 * (`addBoardTaskToBoard` / `updateBoardTaskAndCascade`) and the heal sweep
 * (`linkedCounterWindowHeal.ts`) share:
 *
 *  - {@link materializeWindowCopy} — build + write (insert / revive) the
 *    deterministic per-board row for one {@link LinkedCounterWindowCopy}.
 *  - {@link resolveBoardPlacementTaskId} — the id a placement on `board`
 *    must actually point at.
 *
 * Both MUST run inside an open Dexie `rw` transaction scoping `tasks`,
 * `taskEvents` and `syncQueue`. Swift twin: `AppDatabase+LinkedCounterWindowHeal.swift`.
 */

/**
 * Materialise one per-board window-stamped copy of a linked task.
 *
 * Baseline = the root's increments strictly before the window start, read
 * from `taskEvents`. The row is written through `writeMintedRow`, so an
 * absent id inserts (+ CREATE enqueue), a live id is left untouched, and a
 * tombstoned id is revived with a version bump (so the revive outranks the
 * tombstone under LWW).
 *
 * @param copy - The planned copy (`id` is `derivedTaskId(boardId, root)`).
 * @param sourceTask - The linked row it stands in for (target/title source).
 * @param userId - Owner stamped on a new row.
 * @param now - ISO8601 mint instant.
 * @returns The row now holding `copy.id`, or `null` when the source has no
 *   goal (a goal-less linked row has no per-window target to copy).
 */
export async function materializeWindowCopy(
  copy: LinkedCounterWindowCopy,
  sourceTask: Task,
  userId: string,
  now: string,
): Promise<Task | null> {
  const rootEvents = await db.taskEvents.where('taskId').equals(copy.rootTaskId).toArray();
  const baseline = computeWindowBaseline(copy.rootTaskId, rootEvents, copy.startDate);
  const draft = windowStampedCopyDraft(copy, sourceTask, baseline);
  if (!draft) return null;
  const root = await db.tasks.get(copy.rootTaskId);
  const built = buildDerivedRows({
    drafts: { placementIds: [], derivedTasks: [draft], derivedCompounds: [] },
    userId,
    now,
    rootsById: root ? { [root.id]: root } : {},
    compoundsById: {},
  });
  await writeMintedRow('tasks', built.tasks[0], now);
  return (await db.tasks.get(copy.id)) ?? null;
}

/**
 * The task id a placement on `board` must point at.
 *
 * A task with `sharedCounterId` that is not window-stamped FOR THIS BOARD
 * ({@link isWindowStampedForBoard}) resolves to `derivedTaskId(board.id,
 * root)` — reusing a live row, reviving a tombstoned one, or minting a fresh
 * one — and the root's derived baselines are refreshed. Anything else (a root,
 * a plain counter, a compound, an already-stamped-for-this-board row) is
 * returned unchanged. A goal-less linked task also returns unchanged (nothing
 * to copy; the kernel still evaluates it over the host board's window).
 *
 * This is what makes Board Edit's add / replace square — which bypasses the
 * wizard's `planDerivedTasks` — window-safe.
 *
 * @param board - The board receiving the placement.
 * @param taskId - The task the caller wants to place.
 * @param now - ISO8601 instant for any row written.
 * @returns The id to write into `board_tasks.taskId`.
 */
export async function resolveBoardPlacementTaskId(
  board: Board,
  taskId: string,
  now: string,
): Promise<string> {
  const task = await db.tasks.get(taskId);
  if (!task || !task.sharedCounterId || isWindowStampedForBoard(task, board)) return taskId;
  const root = task.sharedCounterId;
  const copy: LinkedCounterWindowCopy = {
    id: derivedTaskId(board.id, root),
    boardId: board.id,
    boardTaskId: '',
    sourceTaskId: task.id,
    rootTaskId: root,
    timeframe: board.timeframe,
    startDate: board.startDate,
    endDate: board.endDate ?? null,
  };
  const row = await materializeWindowCopy(copy, task, board.userId, now);
  if (!row) return taskId;
  await refreshDerivedBaselines(root);
  return row.id;
}
