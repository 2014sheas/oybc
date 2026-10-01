/**
 * linkedCounterWindowHeal.ts — windowed linked counters (owner rule
 * 2026-10-01: a counting square on a board accounts ONLY for the counter's
 * logs inside that board's window).
 *
 * The *hub-linked* kind of linked counter — `sharedCounterId` set, no window
 * stamp — is retired for anything placed on a board: every linked placement
 * is a per-board window-stamped row. This module is the pure planning half
 * of that migration, shared by both platforms' heal sweeps and placement
 * choke points:
 *
 *   - {@link isWindowStampedForBoard} — is a row THIS board's own per-window
 *     artifact (window-stamped AND stamped for this board's window)?
 *   - {@link planLinkedCounterWindowHeal} — given the task graph, which
 *     hub-linked rows get stamped in place and which placements get a fresh
 *     per-board copy. Deterministic and idempotent: once a platform applies
 *     the plan, a second run over the healed data is empty.
 *   - {@link windowStampedCopyDraft} — the `DerivedTaskDraft` for one copy, so
 *     a platform materialises it through the existing `buildDerivedRows`.
 *
 * Nothing here touches a database: the platform layers apply the plan (web
 * `healLinkedCounterWindows` ↔ iOS `AppDatabase+LinkedCounterWindowHeal`),
 * stamping / minting as AUTHORED writes with deterministic content so every
 * device converges on the same rows.
 *
 * Has a Swift twin (`Helpers/LinkedCounterWindowHeal.swift`), pinned by the
 * same vector fixture (`tests/fixtures/linkedCounterWindowHealVectors.json`,
 * copied byte-identically to `apps/ios/OYBCTests/Fixtures/`). A change here
 * is a change in two places.
 */

import { TaskType, Timeframe } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import { derivedTaskId, isWindowStampedDerived } from './memberRules';
import type { DerivedTaskDraft } from './memberRules';
import { generateCounterTaskTitle } from './taskTitle';

/**
 * Do two stored `startDate`s name the same window opening?
 *
 * `Board.startDate` has TWO live encodings — the local ISO the wizard writes
 * (`2026-09-18T00:00:00`, no offset) and the full UTC form a sync round-trip
 * can hand back — and a derived row copies whichever one its board carried at
 * mint time. Those two never compare equal as strings, so a plain `!==` would
 * answer "not mine" for a re-encoded pull. Comparing INSTANTS is what makes
 * the two encodings agree; a stamp that doesn't parse on either side falls
 * back to string equality rather than claiming a match. Two absent values are
 * equal; an absent and a present one are not.
 *
 * (Moved here from web's `derivedCounters.ts` so both platforms and
 * {@link isWindowStampedForBoard} share one definition.)
 *
 * @param a - One stored start date (a derived row's).
 * @param b - The other (its candidate board's).
 * @returns True when both name the same instant (or the same literal string).
 */
export function sameWindowStart(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return a === b;
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  if (Number.isNaN(ta) || Number.isNaN(tb)) return a === b;
  return ta === tb;
}

/**
 * Is `task` a window-stamped derived counter stamped for THIS board's window
 * — i.e. the row a placement on `board` may point at as-is?
 *
 * The placement choke points' gate: placing a task with a `sharedCounterId`
 * that is NOT window-stamped for the target board (not window-stamped at all,
 * or stamped for a different window) must resolve to that board's own
 * per-window row (`derivedTaskId(board.id, root)`) instead. Only the window
 * START is compared ({@link sameWindowStart}); a row minted for this window
 * carries this board's `endDate` too, and a Board-Edit date change refreshes
 * it through its own path.
 *
 * @param task - The row about to be placed.
 * @param board - The board it is being placed on.
 * @returns True when the row is this board's own window-stamped artifact.
 */
export function isWindowStampedForBoard(
  task: Pick<Task, 'sharedCounterId' | 'startDate' | 'createdInWizard'>,
  board: Pick<Board, 'startDate'>
): boolean {
  return isWindowStampedDerived(task) && sameWindowStart(task.startDate, board.startDate);
}

/** The slices of the task graph {@link planLinkedCounterWindowHeal} reads. */
export interface LinkedCounterWindowHealInput {
  tasks: readonly Pick<
    Task,
    'id' | 'type' | 'sharedCounterId' | 'startDate' | 'endDate' | 'timeframe' | 'createdInWizard' | 'isDeleted' | 'maxCount'
  >[];
  boardTasks: readonly Pick<BoardTask, 'id' | 'boardId' | 'taskId' | 'isDeleted'>[];
  boards: readonly Pick<Board, 'id' | 'timeframe' | 'startDate' | 'endDate' | 'isDeleted'>[];
  compoundChildren: readonly Pick<CompoundChild, 'compoundTaskId' | 'childTaskId' | 'isDeleted'>[];
}

/**
 * Stamp an existing hub-linked row IN PLACE with its first board's window.
 * Applying it sets `timeframe` / `startDate` / `endDate` AND
 * `createdInWizard = true`, so the row becomes `isWindowStampedDerived` and
 * is never a candidate again (the plan's idempotency rests on that flag).
 */
export interface LinkedCounterWindowStamp {
  taskId: string;
  /** The board whose window is stamped (for the caller's cascade). */
  boardId: string;
  timeframe: Timeframe;
  startDate: string;
  endDate: string | null;
}

/**
 * Mint a fresh per-board copy for a FURTHER direct placement of a hub-linked
 * row, and repoint that placement at it. `id` is `derivedTaskId(boardId,
 * rootTaskId)` — the same id the wizard / spawn would mint for this window,
 * so a later re-plan or a concurrent device converges on one row.
 */
export interface LinkedCounterWindowCopy {
  /** `derivedTaskId(boardId, rootTaskId)`. */
  id: string;
  boardId: string;
  /** The `board_tasks` row to repoint from `sourceTaskId` to `id`. */
  boardTaskId: string;
  /** The hub-linked row this copy stands in for on `boardId`. */
  sourceTaskId: string;
  /** The shared-counter root (`sourceTask.sharedCounterId`). */
  rootTaskId: string;
  timeframe: Timeframe;
  startDate: string;
  endDate: string | null;
}

/** Output of {@link planLinkedCounterWindowHeal}. */
export interface LinkedCounterWindowHealPlan {
  stamps: LinkedCounterWindowStamp[];
  copies: LinkedCounterWindowCopy[];
}

type HealBoard = LinkedCounterWindowHealInput['boards'][number];

/**
 * Total order on boards: window start ascending (as INSTANTS, so the two
 * `startDate` encodings sort together), then id. When either start doesn't
 * parse the pair falls back to string order; equal starts tie-break on id.
 */
function compareBoardWindows(a: HealBoard, b: HealBoard): number {
  const ta = Date.parse(a.startDate);
  const tb = Date.parse(b.startDate);
  if (!Number.isNaN(ta) && !Number.isNaN(tb)) {
    if (ta !== tb) return ta < tb ? -1 : 1;
  } else if (a.startDate !== b.startDate) {
    return a.startDate < b.startDate ? -1 : 1;
  }
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** `taskId` then `boardId`, the plan's output order. */
function compareByTaskThenBoard(
  a: { taskId: string; boardId: string },
  b: { taskId: string; boardId: string }
): number {
  if (a.taskId !== b.taskId) return a.taskId < b.taskId ? -1 : 1;
  return a.boardId < b.boardId ? -1 : a.boardId > b.boardId ? 1 : 0;
}

/**
 * Plan the one-time heal of pre-rule hub-linked counters (and any linked row
 * that is windowed but not wizard-born) into per-board window-stamped rows.
 *
 * **Candidates** — non-deleted COUNTING tasks with a `sharedCounterId` that
 * are not {@link isWindowStampedDerived}.
 *
 * **Placing boards** of a candidate — non-deleted boards with a live
 * `board_tasks` row for the task (DIRECT), union non-deleted boards with a
 * live `board_tasks` row for a non-deleted COMPOUND that has a live
 * `compound_children` link to the task (its direct parent only — REACHED).
 * Ordered by (`startDate` asc as instants, `id` asc).
 *
 *   - The FIRST board → a {@link LinkedCounterWindowStamp} (direct or reached
 *     alike): the row itself takes that board's window.
 *   - Every FURTHER **direct** placement → a {@link LinkedCounterWindowCopy}
 *     (`id = derivedTaskId(boardId, root)`, `boardTaskId` = that placement
 *     row, to repoint). Emitted only when the task carries a goal
 *     (`maxCount >= 1`) — a goal-less linked row has no per-window target to
 *     copy, so it is stamped only (documented limitation; the kernel still
 *     evaluates its other placements over their boards' windows).
 *   - Further **reached-only** boards → skipped (documented limitation: a
 *     compound's child link cannot be repointed per board; the kernel's
 *     context-window resolution still renders those boards correctly).
 *   - Unplaced candidates → nothing (library rows keep the lifetime display).
 *
 * Deterministic for a given input (no clock, no rng; every tie is broken by
 * id) and idempotent once applied: a stamped row is window-stamped
 * (`createdInWizard` set by the stamp) and a repointed placement no longer
 * places the source, so the second run over healed data plans nothing.
 * Output is sorted by `taskId` then `boardId`.
 *
 * @param input - See {@link LinkedCounterWindowHealInput}.
 * @returns The stamps and copies to apply.
 */
export function planLinkedCounterWindowHeal(input: LinkedCounterWindowHealInput): LinkedCounterWindowHealPlan {
  const boardsById = new Map<string, HealBoard>();
  for (const b of input.boards) {
    if (!b.isDeleted) boardsById.set(b.id, b);
  }
  const tasksById = new Map<string, LinkedCounterWindowHealInput['tasks'][number]>();
  for (const t of input.tasks) {
    if (!t.isDeleted) tasksById.set(t.id, t);
  }

  // taskId → boardId → the live placement row id (smallest id if a malformed
  // workspace holds two live rows for one task on one board).
  const placementsByTaskId = new Map<string, Map<string, string>>();
  for (const bt of input.boardTasks) {
    if (bt.isDeleted || !boardsById.has(bt.boardId)) continue;
    let byBoard = placementsByTaskId.get(bt.taskId);
    if (!byBoard) {
      byBoard = new Map();
      placementsByTaskId.set(bt.taskId, byBoard);
    }
    const existing = byBoard.get(bt.boardId);
    if (existing === undefined || bt.id < existing) byBoard.set(bt.boardId, bt.id);
  }

  // childId → its live, non-deleted COMPOUND parents.
  const parentsByChildId = new Map<string, Set<string>>();
  for (const link of input.compoundChildren) {
    if (link.isDeleted) continue;
    const parent = tasksById.get(link.compoundTaskId);
    if (!parent || parent.type !== TaskType.COMPOUND) continue;
    let parents = parentsByChildId.get(link.childTaskId);
    if (!parents) {
      parents = new Set();
      parentsByChildId.set(link.childTaskId, parents);
    }
    parents.add(link.compoundTaskId);
  }

  const stamps: LinkedCounterWindowStamp[] = [];
  const copies: LinkedCounterWindowCopy[] = [];

  for (const t of tasksById.values()) {
    if (t.type !== TaskType.COUNTING || !t.sharedCounterId || isWindowStampedDerived(t)) continue;
    const direct = placementsByTaskId.get(t.id) ?? new Map<string, string>();
    const boardIds = new Set<string>(direct.keys());
    for (const parentId of parentsByChildId.get(t.id) ?? []) {
      for (const boardId of placementsByTaskId.get(parentId)?.keys() ?? []) boardIds.add(boardId);
    }
    if (boardIds.size === 0) continue;

    const ordered = [...boardIds].map((id) => boardsById.get(id)!).sort(compareBoardWindows);
    const hasGoal = typeof t.maxCount === 'number' && t.maxCount >= 1;
    ordered.forEach((board, index) => {
      if (index === 0) {
        stamps.push({
          taskId: t.id,
          boardId: board.id,
          timeframe: board.timeframe,
          startDate: board.startDate,
          endDate: board.endDate ?? null,
        });
        return;
      }
      const boardTaskId = direct.get(board.id);
      if (boardTaskId === undefined || !hasGoal) return;
      copies.push({
        id: derivedTaskId(board.id, t.sharedCounterId!),
        boardId: board.id,
        boardTaskId,
        sourceTaskId: t.id,
        rootTaskId: t.sharedCounterId!,
        timeframe: board.timeframe,
        startDate: board.startDate,
        endDate: board.endDate ?? null,
      });
    });
  }

  stamps.sort(compareByTaskThenBoard);
  copies.sort((a, b) =>
    compareByTaskThenBoard(
      { taskId: a.sourceTaskId, boardId: a.boardId },
      { taskId: b.sourceTaskId, boardId: b.boardId }
    )
  );
  return { stamps, copies };
}

/**
 * The `DerivedTaskDraft` for one heal {@link LinkedCounterWindowCopy}, so a
 * platform materialises it through the existing `buildDerivedRows` (which
 * sets `createdInWizard`, mirrors the root's count, stamps the latch, …).
 *
 * Title / action / unit / goal come from the SOURCE row (the copy keeps the
 * hub-linked row's own target — no pro-rating, no vary, exactly what the
 * user had); `replacesId` / `sourceMemberId` are the source; the window is
 * the copy's. `baseline` is the caller's event-derived count of the root at
 * the copy's `startDate` (`computeWindowBaseline`) — a non-authored cache
 * `refreshDerivedBaselines` keeps fresh. Every field is filled purely.
 *
 * Returns `null` for a goal-less source (`maxCount` absent or `< 1`): a
 * derived row needs a per-window target, and {@link planLinkedCounterWindowHeal}
 * never emits a copy for such a row — this is the defensive twin of that rule.
 *
 * @param copy - The planned copy.
 * @param sourceTask - The hub-linked row it stands in for.
 * @param baseline - The root's event-derived count at the copy's window start.
 * @returns The draft, or `null` when the source has no goal.
 */
export function windowStampedCopyDraft(
  copy: LinkedCounterWindowCopy,
  sourceTask: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount'>,
  baseline: number
): DerivedTaskDraft | null {
  if (typeof sourceTask.maxCount !== 'number' || sourceTask.maxCount < 1) return null;
  const maxCount = Math.floor(sourceTask.maxCount);
  const action = sourceTask.action ?? '';
  const unit = sourceTask.unit ?? '';
  return {
    id: copy.id,
    rootTaskId: copy.rootTaskId,
    sourceMemberId: copy.sourceTaskId,
    replacesId: copy.sourceTaskId,
    maxCount,
    baseline: Math.max(0, Math.floor(baseline)),
    title: generateCounterTaskTitle(action, maxCount, unit, action ? undefined : sourceTask.title),
    action,
    unit,
    timeframe: copy.timeframe,
    startDate: copy.startDate,
    endDate: copy.endDate,
  };
}
