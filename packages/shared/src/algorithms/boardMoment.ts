/**
 * boardMoment.ts - the replay kernel behind the Bingo and Greenlog moments
 * (docs/BOARD_MOMENTS.md). When a write completes a line or the whole board,
 * the full-screen moment replays the board from empty: every completed square
 * lands in the order it was completed, a closed line flips green one beat
 * after its last square, and a greenlog ends in a green wave. This module is
 * the pure half, shared by both platforms:
 *
 *   - {@link computeBoardMomentReplay} - the order squares landed in, when each
 *     completed line closes, the rail's counter numbers.
 *   - {@link momentCellVisual} - ONE cell's frame at a beat, derived purely
 *     from `(idx, beat, replay, kind)` so a re-render can never restart a pop
 *     and both platforms draw identical frames.
 *   - {@link momentCounterAt} / {@link momentFinalBeat} - the squares counter
 *     and the clock's last beat.
 *
 * Beat semantics: beat 0 is the empty board (FREE drawn as ink). `order[i]`
 * lands at beat `i + 1`. A line closes one beat after its last non-FREE square
 * lands. A greenlog's wave reaches cell (r, c) at beat
 * `order.length + 1 + r + c`; lines never flip during a greenlog's landing
 * pass.
 *
 * The end state always equals what the play grid shows: membership comes from
 * `computeBoardGrid` (live) or `board.sealedCompletedCells` /
 * `board.completedLineIds` (sealed); instants come from
 * `resolveContributionState` over the board window (events bounded at
 * `sealedAt` on a sealed board) - no second resolver.
 *
 * Has a Swift twin (`Helpers/BoardMoment.swift`) pinned by
 * `tests/fixtures/boardMomentVectors.json` (copied byte-identically to
 * `apps/ios/OYBCTests/Fixtures/`). A change here is a change in two places.
 */

import { detectBingos, getHighlightedSquares, type BoardSize } from '@oybc/bingo-core';
import { CenterSquareType } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { resolveContributionState } from './countsToward';
import { computeBoardGrid } from './derivationPass';
import { boardWindowEnd, boundWindowContextAtSeal } from './taskEvents';

/** Which moment is replaying. */
export type MomentKind = 'bingo' | 'greenlog';

/** One completed non-FREE square, in the replay's landing order. */
export interface MomentOrderEntry {
  boardTaskId: string;
  /** Flat cell index (`row * size + col`). */
  idx: number;
  /** ISO instant the square became complete; `null` when none resolves. */
  completedAt: string | null;
}

/** Everything a moment needs to draw any beat of its replay. */
export interface BoardMomentReplay {
  /**
   * Completed NON-FREE cells in completion order: `completedAt` ascending
   * (parsed-instant compare), null instants after every dated one, ties by
   * `idx`.
   */
  order: MomentOrderEntry[];
  /** The FREE centre's index when the centre is FREE and unoccupied, else `null`. Never in `order`. */
  freeIdx: number | null;
  /** Lines complete in the END state (ids as `detectBingos` emits them) -> the beat they flip green. */
  lineClosureBeat: Record<string, number>;
  /** The rail's numbers, verbatim: `board.completedTasks` / `board.totalTasks`. */
  completedTasks: number;
  totalTasks: number;
  size: number;
}

/** One cell's frame at one beat. */
export interface MomentCellVisual {
  /** The square has landed (drawn in its play colour). Always false for the FREE centre. */
  landed: boolean;
  /** The square is green (a closed line / the greenlog wave). */
  green: boolean;
  /**
   * The beat at which this cell's visual last changed (its landing, then its
   * green flip), `null` before it first changes. A renderer pops a cell when
   * this token changes - never on mount.
   */
  popToken: number | null;
}

/** Parsed ms of an instant, or `null` when absent / unparseable. */
function instantMs(iso: string | null): number | null {
  if (iso == null) return null;
  const ms = new Date(iso).getTime();
  return Number.isNaN(ms) ? null : ms;
}

/** Order: dated before undated; dated by instant then idx; undated by idx. */
function compareEntries(a: MomentOrderEntry, b: MomentOrderEntry): number {
  const ma = instantMs(a.completedAt);
  const mb = instantMs(b.completedAt);
  if (ma !== null && mb !== null) return ma - mb || a.idx - b.idx;
  if (ma !== null) return -1;
  if (mb !== null) return 1;
  return a.idx - b.idx;
}

/**
 * Build the replay for a board.
 *
 * @param board - The board the moment is for.
 * @param boardTasks - The board's placements (any state; tombstones are ignored).
 * @param childrenByCompound - `compoundTaskId` -> live links.
 * @param taskById - Every task by id.
 * @param eventsByTaskId - Non-deleted events grouped by `taskId` (a sealed board is bounded at `sealedAt` here).
 * @param allBoards - Cross-board context for ACHIEVEMENT cells (default none -> they resolve incomplete, as in the kernel).
 * @returns The landing order, FREE index, line closure beats and the rail's numbers.
 */
export function computeBoardMomentReplay(
  board: Board,
  boardTasks: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  eventsByTaskId: Record<string, TaskEvent[]>,
  allBoards: Board[] = [],
): BoardMomentReplay {
  const size = board.boardSize as BoardSize;
  const total = size * size;
  const sealedMs = board.sealedAt != null ? instantMs(board.sealedAt) : null;
  const isSealed = board.sealedAt != null;
  const events = sealedMs !== null ? boundWindowContextAtSeal(eventsByTaskId, sealedMs).eventsByTaskId : eventsByTaskId;

  const { grid, cells } = computeBoardGrid(board, boardTasks, childrenByCompound, taskById, allBoards, { eventsByTaskId: events });

  const completed = new Set<number>();
  if (isSealed) {
    for (const i of board.sealedCompletedCells ?? []) if (i >= 0 && i < total) completed.add(i);
  } else {
    grid.forEach((done, i) => {
      if (done) completed.add(i);
    });
  }

  let freeIdx: number | null = null;
  if (size % 2 === 1 && board.centerSquareType === CenterSquareType.FREE) {
    const mid = Math.floor(size / 2);
    if (!boardTasks.some((bt) => bt.row === mid && bt.col === mid)) freeIdx = mid * size + mid;
  }

  const window = { windowStart: board.startDate, windowEnd: boardWindowEnd(board) };
  const order: MomentOrderEntry[] = [];
  for (const idx of [...completed].sort((a, b) => a - b)) {
    if (idx === freeIdx) continue;
    const state = cells.find((c) => c.idx === idx && c.isCompleted) ?? cells.find((c) => c.idx === idx);
    const placement = state
      ? boardTasks.find((bt) => bt.id === state.boardTaskId)
      : boardTasks.find((bt) => !bt.isDeleted && bt.row * size + bt.col === idx);
    const task = placement ? taskById[placement.taskId] : undefined;
    if (!placement || !task) continue;
    const s = resolveContributionState(task, childrenByCompound, taskById, events, window);
    order.push({ boardTaskId: placement.id, idx, completedAt: s.isCompleted ? s.completedAt : null });
  }
  order.sort(compareEntries);

  const landBeat = new Map<number, number>();
  order.forEach((e, i) => landBeat.set(e.idx, i + 1));

  const endGrid: boolean[] = new Array(total).fill(false);
  for (const i of completed) endGrid[i] = true;
  if (freeIdx !== null) endGrid[freeIdx] = true;
  const lines = isSealed ? (board.completedLineIds ?? []) : detectBingos(endGrid, size).completedLines;

  const lineClosureBeat: Record<string, number> = {};
  for (const lineId of lines) {
    let last = 0;
    for (const idx of getHighlightedSquares([lineId], size)) {
      if (idx === freeIdx) continue;
      last = Math.max(last, landBeat.get(idx) ?? 0);
    }
    lineClosureBeat[lineId] = last + 1;
  }

  return { order, freeIdx, lineClosureBeat, completedTasks: board.completedTasks, totalTasks: board.totalTasks, size };
}

/**
 * One cell's frame at `beat`. Bingo: a cell lands at its order beat and turns
 * green at the earliest closure beat of any closed line containing it (the
 * FREE centre included). Greenlog: cells land in order and every cell turns
 * green when the diagonal wave (`order.length + 1 + row + col`) reaches it;
 * line closures are ignored.
 *
 * @param idx - Flat cell index.
 * @param beat - The replay clock's beat (0 = empty board).
 * @param replay - {@link computeBoardMomentReplay}'s result.
 * @param kind - Which moment is replaying.
 */
export function momentCellVisual(idx: number, beat: number, replay: BoardMomentReplay, kind: MomentKind): MomentCellVisual {
  const position = replay.order.findIndex((e) => e.idx === idx);
  const landBeat = position >= 0 ? position + 1 : null;
  const landed = landBeat !== null && beat >= landBeat;

  let greenBeat: number | null = null;
  if (kind === 'greenlog') {
    greenBeat = replay.order.length + 1 + Math.floor(idx / replay.size) + (idx % replay.size);
  } else {
    for (const [lineId, closure] of Object.entries(replay.lineClosureBeat)) {
      if (!getHighlightedSquares([lineId], replay.size as BoardSize).has(idx)) continue;
      greenBeat = greenBeat === null ? closure : Math.min(greenBeat, closure);
    }
  }
  const green = greenBeat !== null && beat >= greenBeat;
  const popToken = green ? greenBeat : landed ? landBeat : null;
  return { landed, green, popToken };
}

/**
 * The squares counter at `beat`: whatever the rail counts beyond the ordered
 * cells (the FREE centre) is present from beat 0, and each landing adds one,
 * so it ends exactly at `completedTasks`. Never negative.
 */
export function momentCounterAt(beat: number, replay: BoardMomentReplay): number {
  const landed = Math.min(Math.max(beat, 0), replay.order.length);
  return Math.max(0, replay.completedTasks - replay.order.length + landed);
}

/** The clock's last beat: the end state, held. */
export function momentFinalBeat(replay: BoardMomentReplay, kind: MomentKind): number {
  if (kind === 'greenlog') return replay.order.length + 1 + 2 * (replay.size - 1);
  return Math.max(replay.order.length, ...Object.values(replay.lineClosureBeat));
}
