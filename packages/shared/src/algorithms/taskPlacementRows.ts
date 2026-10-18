/**
 * Task Detail's Boards rows — the pure half of placement resolution
 * (docs/TASK_DETAIL_REDESIGN.md PR 5). Swift twin:
 * `apps/ios/OYBC/Helpers/TaskPlacementRows.swift`, pinned by
 * `tests/fixtures/taskPlacementRowsVectors.json`.
 *
 * A task's boards are its placement REACH (`placementsReachedByTasks`, the one
 * reach the cascade and the hub use): its own placements, those of its live
 * linked rows (a counter root), and those of every compound that contains it.
 * Each board's value is read through the same resolvers the board grid uses,
 * over that board's window (bounded at `sealedAt` on a closed board).
 */
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { TaskType } from '../constants/enums';
import { evaluateCompound } from './compoundEvaluation';
import { computeBoardGrid, type ReachedPlacement } from './derivationPass';
import { resolveSquareState, withChildTarget, withPlacementParams } from './placementParams';
import { resolvePlacements } from './placementResolution';
import { boardWindowEnd, boundWindowContextAtSeal, type CompoundWindowContext } from './taskEvents';

/** One board's row: what the task (or the member reached through it) shows there. */
export interface TaskPlacementRow {
  boardId: string;
  /** The placement the row reads (the task's own, a linked row's, or a parent compound's). */
  boardTaskId: string;
  /** The task whose state the row shows — the task itself, a linked row, or a compound's member. */
  memberTaskId: string;
  /** The compound placement this member is reached through, or `null` for a direct placement. */
  viaCompoundId: string | null;
  done: boolean;
  /** Counting member: the windowed count and the goal it is scored against. */
  count: number | null;
  goal: number | null;
  /** Compound member: its direct sub-tasks done in this window / in total. */
  childrenDone: number | null;
  childrenTotal: number | null;
}

export interface TaskPlacementRowsInput {
  /** The task whose detail page this is. */
  taskId: string;
  /** `placementsReachedByTasks([taskId]).placements`. */
  reach: ReadonlyArray<ReachedPlacement>;
  /** Every board the reach names (deleted ones are skipped). */
  boardsById: Readonly<Record<string, Board>>;
  /** Workspace tasks (members, compounds and their sub-tasks, counter roots). */
  taskById: Readonly<Record<string, Task>>;
  /** Live compound links by compound id (nested compounds included). */
  childrenByCompound: Readonly<Record<string, CompoundChild[]>>;
  /** Live events by task id (the members' and their roots'). */
  eventsByTaskId: Readonly<Record<string, TaskEvent[]>>;
  /** Live placements by board id — only an achievement row reads them (its cell needs the whole grid). */
  boardTasksByBoard: Readonly<Record<string, BoardTask[]>>;
  /** Every board (an achievement resolves against the board it watches). */
  allBoards: ReadonlyArray<Board>;
}

/**
 * The reached placement a board's row reads: the task's own direct placement
 * first, then any other direct one (a linked row), then one reached through a
 * compound; ties break on member id, then placement id — independent of the
 * reach's iteration order, so the twins agree.
 */
function pickPerBoard(taskId: string, reach: ReadonlyArray<ReachedPlacement>): Map<string, ReachedPlacement> {
  const rank = (p: ReachedPlacement): number =>
    p.viaCompoundId == null ? (p.memberTaskId === taskId ? 0 : 1) : 2;
  const before = (a: ReachedPlacement, b: ReachedPlacement): boolean =>
    rank(a) !== rank(b) ? rank(a) < rank(b)
      : a.memberTaskId !== b.memberTaskId ? a.memberTaskId < b.memberTaskId
        : a.boardTask.id < b.boardTask.id;
  const best = new Map<string, ReachedPlacement>();
  for (const p of reach) {
    const prev = best.get(p.boardTask.boardId);
    if (!prev || before(p, prev)) best.set(p.boardTask.boardId, p);
  }
  return best;
}

/**
 * One row per board the task reaches, ordered by board id (callers sort for
 * display).
 *
 * @param input - See {@link TaskPlacementRowsInput}.
 * @returns The rows; boards that are missing or deleted, and members that
 *   are missing, are skipped.
 */
export function taskPlacementRows(input: TaskPlacementRowsInput): TaskPlacementRow[] {
  const picked = pickPerBoard(input.taskId, input.reach);
  const order = [...picked.keys()].sort();
  const taskById = input.taskById as Record<string, Task>;
  const children = input.childrenByCompound as Record<string, CompoundChild[]>;
  const rows: TaskPlacementRow[] = [];

  for (const boardId of order) {
    const reached = picked.get(boardId);
    const board = input.boardsById[boardId];
    const member = reached ? taskById[reached.memberTaskId] : undefined;
    if (!reached || !board || board.isDeleted || !member) continue;
    const bt = reached.boardTask;

    const sealedAtMs = board.sealedAt ? new Date(board.sealedAt).getTime() : NaN;
    const events = Number.isNaN(sealedAtMs)
      ? (input.eventsByTaskId as Record<string, TaskEvent[]>)
      : boundWindowContextAtSeal(input.eventsByTaskId as Record<string, TaskEvent[]>, sealedAtMs).eventsByTaskId;
    const ctx: CompoundWindowContext = { windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: events };

    // Direct: the placement's own parameters. Via a compound: the parent
    // placement's child target applies only to its DIRECT children.
    const direct = reached.viaCompoundId == null;
    const isDirectChild = !direct && (children[reached.viaCompoundId as string] ?? []).some(
      (l) => !l.isDeleted && l.childTaskId === member.id,
    );
    const subject = direct ? withPlacementParams(member, bt) : withChildTarget(member, isDirectChild ? bt.childTargets : undefined);

    let done: boolean;
    let count: number | null = null;
    let goal: number | null = null;
    let childrenDone: number | null = null;
    let childrenTotal: number | null = null;

    if (subject.type === TaskType.COMPOUND) {
      const ownTargets = direct ? bt.childTargets : undefined;
      done = evaluateCompound(subject, children, taskById, ctx, ownTargets);
      const kids = (children[subject.id] ?? []).filter((l) => !l.isDeleted).flatMap((l) => {
        const t = taskById[l.childTaskId];
        return t && !t.isDeleted ? [withChildTarget(t, ownTargets)] : [];
      });
      childrenTotal = kids.length;
      childrenDone = kids.filter((k) =>
        k.type === TaskType.COMPOUND ? evaluateCompound(k, children, taskById, ctx) : resolveSquareState(k, undefined, ctx).isCompleted,
      ).length;
    } else if (subject.type === TaskType.ACHIEVEMENT) {
      // An achievement's state is its cell in the board's own grid.
      const onBoard = resolvePlacements(input.boardTasksByBoard[boardId] ?? [], board.boardSize);
      const grid = computeBoardGrid(board, onBoard, children, taskById, [...input.allBoards], { eventsByTaskId: events });
      done = grid.cells.find((c) => c.boardTaskId === bt.id)?.isCompleted ?? false;
    } else {
      const state = resolveSquareState(subject, undefined, ctx);
      done = state.isCompleted;
      if (subject.type === TaskType.COUNTING) {
        count = state.count;
        goal = subject.maxCount ?? null;
      }
    }

    // A closed board's own cell is its frozen record.
    if (direct && board.sealedAt) {
      done = (board.sealedCompletedCells ?? []).includes(bt.row * board.boardSize + bt.col);
    }

    rows.push({
      boardId, boardTaskId: bt.id, memberTaskId: member.id, viaCompoundId: reached.viaCompoundId,
      done, count, goal, childrenDone, childrenTotal,
    });
  }
  return rows;
}
