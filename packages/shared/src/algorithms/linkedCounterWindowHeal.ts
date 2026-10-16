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
import type { CountKind } from './countValue';
import { isWholeCountKind, quantizeCount, resolveCountKind } from './countValue';
import { derivedTaskId, isWindowStampedDerived } from './memberRules';
import type { DerivedTaskDraft } from './memberRules';
import { counterCopyTitle, type CounterTitleSettings } from './taskTitle';

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

/**
 * Whether a goal can seed a per-window copy: whole kinds need `>= 1`, a
 * continuous goal any positive value (a 0.5-mile goal is legitimate).
 */
function hasCopyGoal(maxCount: number | null | undefined, kind: CountKind): boolean {
  if (typeof maxCount !== 'number') return false;
  return isWholeCountKind(kind) ? maxCount >= 1 : maxCount > 0;
}

/** The slices of the task graph {@link planLinkedCounterWindowHeal} reads. */
export interface LinkedCounterWindowHealInput {
  tasks: readonly Pick<
    Task,
    'id' | 'type' | 'sharedCounterId' | 'startDate' | 'endDate' | 'timeframe' | 'createdInWizard' | 'isDeleted' | 'maxCount' | 'countKind'
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
 * Mint a fresh per-board copy for a direct placement that cannot keep its
 * row — a FURTHER placement of a hub-linked row being stamped elsewhere, or
 * a window-stamped row placed on a board it is not stamped for — and
 * repoint that placement at it. `id` is `derivedTaskId(boardId,
 * rootTaskId)` — the same id the wizard / spawn would mint for this window,
 * so a later re-plan or a concurrent device converges on one row.
 */
export interface LinkedCounterWindowCopy {
  /** `derivedTaskId(boardId, rootTaskId)`. */
  id: string;
  boardId: string;
  /** The `board_tasks` row to repoint from `sourceTaskId` to `id`. */
  boardTaskId: string;
  /** The linked row this copy stands in for on `boardId`. */
  sourceTaskId: string;
  /** The shared-counter root (`sourceTask.sharedCounterId`). */
  rootTaskId: string;
  timeframe: Timeframe;
  startDate: string;
  endDate: string | null;
}

/**
 * Clear a window-stamped row's stamp (`timeframe` / `startDate` / `endDate`)
 * so it is hub-linked again and the kernel's context-window fallback renders
 * it over the HOST board's window wherever a compound carries it. Planned
 * only for a row that is a live compound's child and is not any board's own
 * per-window artifact (see {@link planLinkedCounterWindowHeal} rule 3).
 * `createdInWizard` is left as it is (it is not a window mark on its own).
 */
export interface LinkedCounterWindowUnstamp {
  taskId: string;
}

/** Output of {@link planLinkedCounterWindowHeal}. */
export interface LinkedCounterWindowHealPlan {
  stamps: LinkedCounterWindowStamp[];
  copies: LinkedCounterWindowCopy[];
  unstamps: LinkedCounterWindowUnstamp[];
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
 * Plan the (idempotent) heal of linked counters into per-board window-stamped
 * rows: pre-rule hub-linked rows (and any linked row that is windowed but
 * not wizard-born) get stamped / copied, window-stamped rows sitting on a
 * board they are not stamped for get a copy, and a stamped row that a
 * compound carries gets its stamp cleared.
 *
 * **Direct placements** of a row — non-deleted boards with a live
 * `board_tasks` row for the task. **Compound members** — rows with a live
 * `compound_children` link from a non-deleted COMPOUND (its direct parent
 * only). A member is REACHED on every board its parent is placed on, and a
 * child link cannot be repointed per board.
 *
 * **1. Unstamped candidates** — non-deleted COUNTING tasks with a
 * `sharedCounterId` that are not {@link isWindowStampedDerived}. Once
 * stamped, a row is resolved from its OWN stamped window everywhere
 * (`resolveDerivedCounterWindowState` / `resolveLinkedCounterDisplay` take
 * the stamped path and ignore the context window), so:
 *
 *   - A row that is NOT a compound member: the FIRST direct board (ordered
 *     by `startDate` asc as instants, then `id`) → a
 *     {@link LinkedCounterWindowStamp} (the row itself takes that board's
 *     window) and every further direct board → a
 *     {@link LinkedCounterWindowCopy} (`id = derivedTaskId(boardId, root)`,
 *     `boardTaskId` = that placement row, to repoint). More than one board
 *     requires a goal (`maxCount >= 1` — a copy needs a per-window target);
 *     a goal-less row on more than one board → nothing. Unplaced → nothing
 *     (library rows keep the lifetime display).
 *   - A row that IS a compound member is NEVER stamped (incident
 *     2026-10-16: a daily series re-places the same compound every window,
 *     so a child stamped with the first window read 0 on every later board
 *     and was frozen out of propagation). It stays hub-linked — the kernel's
 *     context-window fallback renders every board over its own window —
 *     and, when it has a goal, each of its DIRECT placements gets a copy
 *     (a direct square is still per-board, like any other). Goal-less →
 *     nothing.
 *
 * **2. Mis-placed window-stamped rows** — non-deleted COUNTING rows that ARE
 * {@link isWindowStampedDerived} with a live DIRECT placement on a board
 * for which they are not {@link isWindowStampedForBoard} (a row stamped for
 * board X placed on board Y — an old-app device placing it, or a partial
 * graph that stamped the wrong "first board"). Each such placement → a
 * {@link LinkedCounterWindowCopy} for board Y; the row keeps its own window
 * (no stamp). Requires a goal (goal-less → nothing). A placement whose
 * board's deterministic id IS the row's own id is left alone — that row is
 * already the board's per-window artifact and only its dates are stale,
 * which the Board Edit date path owns (a copy would point the placement at
 * itself forever).
 *
 * **3. Stamped compound members** — a window-stamped COUNTING row that is a
 * compound member and is NOT any live board's own artifact (no live board
 * `b` has `derivedTaskId(b.id, root) === id`; the planner / spawn / Board
 * Edit mint their per-window children under THAT id and link them from a
 * per-window derived compound, which keeps them) → a
 * {@link LinkedCounterWindowUnstamp}: the stamp an earlier heal (or an
 * old-app device) put on a hand-made / wizard-born child is cleared, and —
 * with a goal — every direct placement gets a copy as in rule 1 (the row is
 * no longer stamped for any board, so none is skipped).
 *
 * Deterministic for a given input (no clock, no rng; every tie is broken by
 * id) and idempotent once applied: a stamped row is window-stamped
 * (`createdInWizard` set by the stamp), a repointed placement places the
 * board's own row (window-stamped for that board) instead of the source,
 * and an un-stamped member has no direct placement left to copy — so the
 * second run over healed data plans nothing. Output is sorted by `taskId`
 * then `boardId`.
 *
 * @param input - See {@link LinkedCounterWindowHealInput}.
 * @returns The stamps, copies and unstamps to apply.
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
  const unstamps: LinkedCounterWindowUnstamp[] = [];
  const liveBoards = [...boardsById.values()];

  const copyFor = (
    t: LinkedCounterWindowHealInput['tasks'][number],
    board: HealBoard,
    boardTaskId: string
  ): LinkedCounterWindowCopy => ({
    id: derivedTaskId(board.id, t.sharedCounterId!),
    boardId: board.id,
    boardTaskId,
    sourceTaskId: t.id,
    rootTaskId: t.sharedCounterId!,
    timeframe: board.timeframe,
    startDate: board.startDate,
    endDate: board.endDate ?? null,
  });

  /** Is `t` some live board's own per-window artifact (`derivedTaskId(b, root)`)? */
  const isBoardArtifact = (t: LinkedCounterWindowHealInput['tasks'][number]): boolean =>
    liveBoards.some((b) => derivedTaskId(b.id, t.sharedCounterId!) === t.id);

  for (const t of tasksById.values()) {
    if (t.type !== TaskType.COUNTING || !t.sharedCounterId) continue;
    const direct = placementsByTaskId.get(t.id) ?? new Map<string, string>();
    const hasGoal = hasCopyGoal(t.maxCount, resolveCountKind(t));
    const isMember = (parentsByChildId.get(t.id)?.size ?? 0) > 0;

    if (isWindowStampedDerived(t)) {
      // 3. A stamped compound member that is no board's artifact: clear the
      //    stamp; its direct placements are then copied like any unstamped
      //    member's (no board is "its own" any more).
      const unstamp = isMember && !isBoardArtifact(t);
      if (unstamp) unstamps.push({ taskId: t.id });
      // 2. Mis-placed window-stamped rows: a copy per direct placement on a
      //    board the row is not stamped for; the row keeps its own window.
      if (!hasGoal) continue;
      for (const [boardId, boardTaskId] of direct) {
        const board = boardsById.get(boardId)!;
        if (!unstamp && isWindowStampedForBoard(t, board)) continue;
        if (derivedTaskId(board.id, t.sharedCounterId) === t.id) continue;
        copies.push(copyFor(t, board, boardTaskId));
      }
      continue;
    }

    if (isMember) {
      // 1b. A compound member is never stamped; with a goal, each direct
      //     placement gets its own per-board copy.
      if (!hasGoal) continue;
      for (const [boardId, boardTaskId] of direct) {
        const board = boardsById.get(boardId)!;
        if (derivedTaskId(board.id, t.sharedCounterId) === t.id) continue;
        copies.push(copyFor(t, board, boardTaskId));
      }
      continue;
    }

    // 1a. Unstamped non-member: stamp the first direct board and copy every
    //     further one — or do nothing at all.
    if (direct.size === 0) continue;
    const ordered = [...direct.keys()].map((id) => boardsById.get(id)!).sort(compareBoardWindows);
    const [first, ...further] = ordered;
    if (further.length > 0 && !hasGoal) continue;

    stamps.push({
      taskId: t.id,
      boardId: first.id,
      timeframe: first.timeframe,
      startDate: first.startDate,
      endDate: first.endDate ?? null,
    });
    for (const board of further) copies.push(copyFor(t, board, direct.get(board.id)!));
  }

  stamps.sort(compareByTaskThenBoard);
  copies.sort((a, b) =>
    compareByTaskThenBoard(
      { taskId: a.sourceTaskId, boardId: a.boardId },
      { taskId: b.sourceTaskId, boardId: b.boardId }
    )
  );
  unstamps.sort((a, b) => (a.taskId < b.taskId ? -1 : a.taskId > b.taskId ? 1 : 0));
  return { stamps, copies, unstamps };
}

/**
 * The `DerivedTaskDraft` for one heal {@link LinkedCounterWindowCopy}, so a
 * platform materialises it through the existing `buildDerivedRows` (which
 * sets `createdInWizard`, mirrors the root's count, stamps the latch, …).
 *
 * Action / unit / goal come from the SOURCE row (the copy keeps the
 * linked row's own target — no pro-rating, no vary, exactly what the
 * user had); the title is `counterCopyTitle` — a custom name carries over
 * verbatim, an auto one is regenerated (2026-10-06); `replacesId` /
 * `sourceMemberId` are the source; the window is the copy's. `baseline` is the caller's event-derived count of the root at
 * the copy's `startDate` (`computeWindowBaseline`) — a non-authored cache
 * `refreshDerivedBaselines` keeps fresh. Every field is filled purely.
 *
 * Returns `null` for a goal-less source (`maxCount` absent or `< 1`): a
 * derived row needs a per-window target, and {@link planLinkedCounterWindowHeal}
 * never emits a copy for such a row — this is the defensive twin of that rule.
 *
 * `options` (docs/SHARED_COUNTER_SETTINGS.md §2): `settings` = the ROOT's
 * name + templates, so the copy's title is judged and rendered through them
 * (a linked source carries none of its own); `maxCount` = the placement goal
 * (`placementGoalForCounter`) overriding the source's — the Board Edit
 * placement path passes both, the heal sweep passes only `settings`.
 *
 * @param copy - The planned copy.
 * @param sourceTask - The linked row it stands in for.
 * @param baseline - The root's event-derived count at the copy's window start.
 * @param options - Optional root settings and goal override.
 * @returns The draft, or `null` when there is no goal.
 */
export function windowStampedCopyDraft(
  copy: LinkedCounterWindowCopy,
  sourceTask: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount' | 'countKind'>,
  baseline: number,
  options: { settings?: CounterTitleSettings | null; maxCount?: number | null } = {}
): DerivedTaskDraft | null {
  const countKind = resolveCountKind(sourceTask);
  const goal = options.maxCount ?? sourceTask.maxCount;
  if (!hasCopyGoal(goal, countKind)) return null;
  const whole = (x: number): number => (isWholeCountKind(countKind) ? Math.floor(x) : quantizeCount(x));
  const maxCount = whole(goal!);
  const action = sourceTask.action ?? '';
  const unit = sourceTask.unit ?? '';
  return {
    id: copy.id,
    rootTaskId: copy.rootTaskId,
    sourceMemberId: copy.sourceTaskId,
    replacesId: copy.sourceTaskId,
    maxCount,
    countKind,
    baseline: Math.max(0, whole(baseline)),
    title: counterCopyTitle(sourceTask, maxCount, options.settings ?? null),
    action,
    unit,
    timeframe: copy.timeframe,
    startDate: copy.startDate,
    endDate: copy.endDate,
  };
}
