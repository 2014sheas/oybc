/**
 * boardScopedFork.ts — board-scoped task edits, foundation (PR 1 of the
 * train in docs/BOARD_SCOPED_TASK_EDITS.md §9).
 *
 * Owner ruling 2026-10-08: an edit made from a board (Board Edit, the board
 * wizard) affects the task ONLY on that board. When the task is placed on
 * any other board, the edit lands on a **fork** — a new Task that replaces
 * the original on this board's placement. This module is the pure planning
 * half:
 *
 *   - {@link forkTaskId} / {@link forkedEventId} / {@link forkLinkId} — the
 *     deterministic uuidv5 ids (the `derivedTaskId` seam, own name prefixes),
 *     so two devices forking the same square offline converge on one row and
 *     a replayed fork is idempotent (§7).
 *   - {@link planBoardScopedFork} — decide in-place vs fork (§2, D1/D2) and,
 *     for a fork, build the fork row, the in-window event copies (§4, D4 (a))
 *     and the compound child-link copies (§6).
 *
 * PR 2 consumes the plan inside the Board Edit / wizard commit
 * transactions; {@link wouldForkOnBoard} drives the Board Edit sheet's
 * button label from the same test. No persistence, no clock, no platform
 * code.
 *
 * Has a Swift twin (`Helpers/BoardScopedFork.swift`), pinned by the same
 * vector fixture (`tests/fixtures/boardScopedForkVectors.json`, copied
 * byte-identically to `apps/ios/OYBCTests/Fixtures/`). A change here is a
 * change in two places.
 */

import { TaskType } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent, TaskEventKind } from '../types/taskEvent';
import { findTransitiveParentCompounds } from './derivationPass';
import { uuidv5 } from './uuidv5';

/** uuidv5 name prefix for a board-scoped fork of a task. */
export const FORK_TASK_NS = 'fork:task';
/** uuidv5 name prefix for an event copied onto a fork. */
export const FORK_EVENT_NS = 'fork:event';
/** uuidv5 name prefix for a `compound_children` link copied onto a forked compound. */
export const FORK_LINK_NS = 'fork:link';

/**
 * Deterministic id of the fork of `taskId` on `boardId`.
 *
 * @param boardId - The board the edit is made from.
 * @param taskId - The task being forked (the original).
 * @returns A stable uuidv5 — forking the same square again yields the same id.
 */
export function forkTaskId(boardId: string, taskId: string): string {
  return uuidv5(`${FORK_TASK_NS}:${boardId}:${taskId}`);
}

/**
 * Deterministic id of the copy of `eventId` migrated onto `forkId`.
 *
 * Keyed on the FORK as well as the event (the spec sketch keyed on the event
 * alone): one event can sit inside two overlapping windows — a daily inside
 * its monthly — and so be migrated onto two different forks; an event-only
 * id would collide across them.
 *
 * @param forkId - The fork the copy belongs to (from {@link forkTaskId}).
 * @param eventId - The original event's id.
 * @returns A stable uuidv5.
 */
export function forkedEventId(forkId: string, eventId: string): string {
  return uuidv5(`${FORK_EVENT_NS}:${forkId}:${eventId}`);
}

/**
 * Deterministic id of the `compound_children` link from a forked compound to
 * one of the original's (shared) children.
 *
 * @param forkId - The forked compound's id (from {@link forkTaskId}).
 * @param childTaskId - The child task the link points at.
 * @returns A stable uuidv5.
 */
export function forkLinkId(forkId: string, childTaskId: string): string {
  return uuidv5(`${FORK_LINK_NS}:${forkId}:${childTaskId}`);
}

/** Input of {@link planBoardScopedFork}. */
export interface BoardScopedForkInput {
  /** The task being edited from the board (pre-edit row). */
  task: Task;
  /** The board the edit is made from. */
  board: Pick<Board, 'id' | 'startDate' | 'endDate' | 'sealedAt'>;
  /**
   * The task type AFTER the edit (the fork keeps the original's fields — the
   * caller applies the edit to it). Selects which events migrate (§4).
   */
  editedType: TaskType;
  /**
   * `board_tasks` rows placing the task or any of its (transitive) parent
   * compounds — passing more is harmless, rows for other tasks are ignored.
   */
  placements: readonly Pick<BoardTask, 'id' | 'boardId' | 'taskId' | 'isDeleted'>[];
  /** Boards referenced by `placements`. A board absent here is treated as not live. */
  boards: readonly Pick<Board, 'id' | 'isDeleted'>[];
  /** `compound_children` links: the task's parents (reachability) and, for a compound, its children. */
  compoundChildren: readonly CompoundChild[];
  /** The task's events (rows for other tasks are ignored). */
  events: readonly TaskEvent[];
  /** The write instant (ISO8601) stamped on every row the plan mints. */
  now: string;
}

/** Repoint the edited board's placement from the original to the fork. */
export interface BoardScopedForkRepoint {
  boardTaskId: string;
  newTaskId: string;
}

/** Output of {@link planBoardScopedFork}. */
export type BoardScopedForkPlan =
  | { mode: 'inPlace' }
  | {
      mode: 'fork';
      /** The fork row to insert (before the caller applies the edit to it). */
      fork: Task;
      /** In-window events of the original, copied onto the fork. */
      eventCopies: TaskEvent[];
      /** For a compound: its live child links, copied onto the fork (children stay shared). */
      childLinksToCopy: CompoundChild[];
      /**
       * The edited board's DIRECT placement of the task, to repoint at the
       * fork — `null` when the task is on this board only through a compound
       * (PR 2 repoints that compound's link instead).
       */
      repoint: BoardScopedForkRepoint | null;
      /**
       * The compounds with a live placement on THIS board that contain the
       * task directly or transitively (over live links), sorted by id. The
       * fork must replace the task inside each of them too: PR 2 repoints the
       * task's link within each holder's subtree — and forks a holder that is
       * itself placed elsewhere before repointing the copied link. Empty when
       * the task is on this board only as a direct placement.
       */
      onBoardHolderCompoundIds: string[];
    };

/** Input of {@link wouldForkOnBoard} — the placement half of {@link BoardScopedForkInput}. */
export interface WouldForkOnBoardInput {
  /** The task the board edit targets (pre-edit row). */
  task: Pick<Task, 'id' | 'forkedFromTaskId' | 'sharedCounterId'>;
  /** The board the edit is made from. */
  boardId: string;
  /** `board_tasks` rows (rows for unrelated tasks are ignored). */
  placements: readonly Pick<BoardTask, 'id' | 'boardId' | 'taskId' | 'isDeleted'>[];
  /** Boards referenced by `placements`; a board absent here is not live. */
  boards: readonly Pick<Board, 'id' | 'isDeleted'>[];
  /** `compound_children` links (the task's parents, for reachability). */
  compoundChildren: readonly CompoundChild[];
}

/**
 * Whether a board edit of `task` from `boardId` would land on a fork — the
 * §2 "other placements" test alone, so the Board Edit sheet's button label
 * ("Save for this board") and the Save commit
 * ({@link planBoardScopedFork}, which calls this) can never disagree.
 *
 * False for a fork (never re-forked) and a linked counter (already this
 * board's copy). Otherwise true iff the task — directly, or through any
 * (transitive) parent compound over live links — has a live placement on a
 * board OTHER than `boardId`. Live = `BoardTask` not deleted and its board
 * present in `boards` and not deleted; sealed / archived boards count (D1).
 *
 * @param input - See {@link WouldForkOnBoardInput}.
 * @returns `true` when the edit must fork.
 */
export function wouldForkOnBoard(input: WouldForkOnBoardInput): boolean {
  const { task, boardId } = input;
  if (task.forkedFromTaskId != null || task.sharedCounterId != null) return false;
  const liveBoardIds = new Set(input.boards.filter((b) => !b.isDeleted).map((b) => b.id));
  const holders = findTransitiveParentCompounds(task.id, [...input.compoundChildren]);
  holders.add(task.id);
  return input.placements.some(
    (p) => !p.isDeleted && p.boardId !== boardId && holders.has(p.taskId) && liveBoardIds.has(p.boardId),
  );
}

/** The event kind a task type owns, or `null` for a type that owns none (§4). */
function ownedEventKind(type: TaskType): TaskEventKind | null {
  if (type === TaskType.NORMAL) return 'completion';
  if (type === TaskType.COUNTING) return 'increment';
  return null;
}

/** Parse an ISO instant to epoch ms (`NaN` when unparseable). */
function ms(iso: string): number {
  return new Date(iso).getTime();
}

/**
 * Plan a board-scoped edit of `task` from `board` (docs/BOARD_SCOPED_TASK_EDITS.md).
 *
 * **In place** when the task is already a fork (`forkedFromTaskId` set — a
 * fork is never re-forked, §3) or a linked counter (`sharedCounterId` set —
 * a placed linked counter IS this board's per-window copy, §6), or when no
 * OTHER live placement exists (§2). A placement is live when its
 * `BoardTask` is not deleted and its board is present and not deleted —
 * **sealed and archived boards count** (D1). Placements reach the task
 * directly or through any (transitive) parent compound over live links, so
 * a child shown on another board inside a compound counts too. Placements on
 * the edited board itself never count. Pool / template membership is not a
 * placement (D2).
 *
 * **Fork** otherwise:
 *
 *   - `fork` = the original row with `id = forkTaskId(board, task)`,
 *     `forkedFromTaskId = task.id`, `createdInWizard = true` (library-hidden),
 *     `isCounter = false` (a fork is board-bound, never a hub counter),
 *     `version = 1`, `createdAt = updatedAt = now`, sync metadata dropped,
 *     and the lifetime caches RESET (`isCompleted` false, no `completedAt`,
 *     `currentCount` 0 for counting else absent, `totalCompletions` 0,
 *     `totalInstances` 1). The caches are not derived here on purpose: they
 *     depend on the POST-edit task (type, goal), so PR 2's commit stamps them
 *     from the fork's events (`computeTaskCachesFromEvents`) after applying
 *     the edit, in the same transaction.
 *   - `eventCopies` = every non-deleted event of the original whose
 *     `occurredAt` lies in `[startDate, min(endDate, sealedAt)]` (inclusive
 *     both ends, parsed-instant compare; `endDate` absent = open-ended; an
 *     unparseable bound admits nothing, as in `resolveTaskWindowState`) and
 *     whose kind the EDITED type owns (Normal → completions, Counting →
 *     increments, Compound/Achievement → none). Each copy keeps `userId`,
 *     `kind`, `delta`, `occurredAt`, `boardId`; gets
 *     `id = forkedEventId(fork, event)`, `taskId = fork`, `version 1`,
 *     `createdAt = updatedAt = now`. Ordered by `occurredAt` instant, then
 *     original id.
 *   - `childLinksToCopy` = the original's live `compound_children` links,
 *     re-parented onto the fork (`id = forkLinkId(fork, child)`, same
 *     `childIndex`), ordered by `childIndex` then original id. Children are
 *     NOT forked here — a child edited from the board goes through its own
 *     plan (PR 2).
 *   - `repoint` = the smallest-id live placement of the task on this board,
 *     or `null`; `onBoardHolderCompoundIds` = the placed compounds on this
 *     board that contain the task (see {@link BoardScopedForkPlan}).
 *
 * Pure and deterministic: no clock (the caller passes `now`), no rng, every
 * tie broken by id; inputs are not mutated.
 *
 * @param input - See {@link BoardScopedForkInput}.
 * @returns The plan.
 */
export function planBoardScopedFork(input: BoardScopedForkInput): BoardScopedForkPlan {
  const { task, board, now } = input;
  if (!wouldForkOnBoard({ ...input, boardId: board.id })) return { mode: 'inPlace' };

  const liveBoardIds = new Set(input.boards.filter((b) => !b.isDeleted).map((b) => b.id));
  const holders = findTransitiveParentCompounds(task.id, [...input.compoundChildren]);
  holders.add(task.id);

  let repointId: string | null = null;
  const onBoardHolders = new Set<string>();
  for (const p of input.placements) {
    if (p.isDeleted || p.boardId !== board.id || !holders.has(p.taskId) || !liveBoardIds.has(p.boardId)) continue;
    if (p.taskId !== task.id) onBoardHolders.add(p.taskId);
    else if (repointId === null || p.id < repointId) repointId = p.id;
  }

  const forkId = forkTaskId(board.id, task.id);
  const {
    lastSyncedAt: _lastSyncedAt,
    deletedAt: _deletedAt,
    completedAt: _completedAt,
    ...kept
  } = task;
  const fork: Task = {
    ...kept,
    id: forkId,
    forkedFromTaskId: task.id,
    createdInWizard: true,
    isCounter: false,
    version: 1,
    createdAt: now,
    updatedAt: now,
    isDeleted: false,
    isCompleted: false,
    currentCount: task.type === TaskType.COUNTING ? 0 : undefined,
    totalCompletions: 0,
    totalInstances: 1,
  };
  if (fork.currentCount === undefined) delete fork.currentCount;

  const kind = ownedEventKind(input.editedType);
  const lower = ms(board.startDate);
  const bounds = [board.endDate, board.sealedAt].filter((x): x is string => x != null).map(ms);
  const inWindow = (e: TaskEvent): boolean => {
    const t = ms(e.occurredAt);
    return t >= lower && bounds.every((b) => t <= b);
  };
  const eventCopies = kind === null
    ? []
    : input.events
        .filter((e) => e.taskId === task.id && !e.isDeleted && e.kind === kind && inWindow(e))
        .sort((a, b) => ms(a.occurredAt) - ms(b.occurredAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .map((e): TaskEvent => {
          const { lastSyncedAt: _l, deletedAt: _d, ...rest } = e;
          return {
            ...rest,
            id: forkedEventId(forkId, e.id),
            taskId: forkId,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
          };
        });

  const childLinksToCopy = input.compoundChildren
    .filter((l) => !l.isDeleted && l.compoundTaskId === task.id)
    .sort((a, b) => a.childIndex - b.childIndex || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .map((l): CompoundChild => ({
      id: forkLinkId(forkId, l.childTaskId),
      compoundTaskId: forkId,
      childTaskId: l.childTaskId,
      childIndex: l.childIndex,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    }));

  return {
    mode: 'fork',
    fork,
    eventCopies,
    childLinksToCopy,
    repoint: repointId === null ? null : { boardTaskId: repointId, newTaskId: forkId },
    onBoardHolderCompoundIds: [...onBoardHolders].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
  };
}
