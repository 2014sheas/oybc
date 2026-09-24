import * as fs from 'fs';
import * as path from 'path';
import {
  computeBoardStatsUpdate,
  computeSealedCompletedCells,
} from '../../src/algorithms/derivationPass';
import {
  boundWindowContextAtSeal,
  type WindowEvaluationContext,
} from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, Board, BoardTask, CompoundChild } from '../../src/types';
import {
  TaskType,
  Timeframe,
  BoardStatus,
  CenterSquareType,
  OperatorType,
} from '../../src/constants/enums';

/**
 * sealReDerivation.test.ts — Windowed Completion PR A seal-snapshot builder
 * (docs/WINDOWED_COMPLETION.md §Seal snapshots re-derive from the event union).
 * Fixture-driven from `tests/fixtures/sealReDerivationVectors.json` — the SAME
 * file run by iOS `TaskEventVectorTests.swift`. Property:
 * the green cell set is a pure function of the converged in-window event union,
 * so the same union (any order) yields the same cells on any device.
 */

interface VectorBoard {
  id: string;
  boardSize: number;
  centerSquareType: string;
  startDate: string;
  endDate: string | null;
  status: string;
  linesCompleted: number;
  completedLineIds: string[] | null;
  isDeleted: boolean;
}
interface VectorTask {
  id: string;
  type: string;
  maxCount: number | null;
  sharedCounterId: string | null;
  /** Compound tasks only (Task-4 breadth vectors). */
  operator?: string | null;
  threshold?: number | null;
  /** Optional — window-stamped derived counters (2026-09-23 amendment). */
  startDate?: string | null;
  endDate?: string | null;
  createdInWizard?: boolean;
  isCompleted: boolean;
  isDeleted: boolean;
}
interface VectorCompoundChild {
  compoundTaskId: string;
  childTaskId: string;
  childIndex: number;
  isDeleted: boolean;
}
interface VectorEvent {
  id: string;
  taskId: string;
  kind: 'completion' | 'increment';
  delta: number | null;
  occurredAt: string;
  isDeleted: boolean;
}
interface Vector {
  name: string;
  board: VectorBoard;
  tasks: VectorTask[];
  boardTasks: { taskId: string; row: number; col: number }[];
  events: VectorEvent[];
  /** Optional — when present, the event union is bounded at this instant via
   *  the shared `boundWindowContextAtSeal` (what both platforms' sealing data
   *  layers do before deriving a sealed snapshot). */
  sealedAt?: string;
  /** Optional — compound links (absent = none). */
  compoundChildren?: VectorCompoundChild[];
  expectedCells: number[];
  /** Optional — the sealed snapshot's frozen stats (computeBoardStatsUpdate). */
  expectedCompletedTasks?: number;
  expectedLinesCompleted?: number;
  expectedCompletedLineIds?: string[];
}

interface SealResult {
  cells: number[];
  completedTasks: number;
  linesCompleted: number;
  completedLineIds: string[];
}

const fixture: { vectors: Vector[] } = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/sealReDerivationVectors.json'), 'utf8'),
);

function toBoard(b: VectorBoard): Board {
  return {
    id: b.id,
    userId: 'user-1',
    name: 'B',
    status: b.status as BoardStatus,
    boardSize: b.boardSize as Board['boardSize'],
    timeframe: Timeframe.DAILY,
    startDate: b.startDate,
    endDate: b.endDate ?? undefined,
    centerSquareType: b.centerSquareType as CenterSquareType,
    isRandomized: false,
    totalTasks: b.boardSize * b.boardSize,
    completedTasks: 0,
    linesCompleted: b.linesCompleted,
    completedLineIds: b.completedLineIds ?? undefined,
    createdAt: b.startDate,
    updatedAt: b.startDate,
    version: 1,
    isDeleted: b.isDeleted,
  };
}

function toTask(t: VectorTask): Task {
  return {
    id: t.id,
    userId: 'user-1',
    title: 'T',
    type: t.type as TaskType,
    maxCount: t.maxCount ?? undefined,
    sharedCounterId: t.sharedCounterId,
    operator: (t.operator ?? undefined) as OperatorType | undefined,
    threshold: t.threshold ?? undefined,
    startDate: t.startDate ?? undefined,
    endDate: t.endDate ?? undefined,
    createdInWizard: t.createdInWizard ?? false,
    isCompleted: t.isCompleted,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: t.id,
    updatedAt: t.id,
    version: 1,
    isDeleted: t.isDeleted,
  };
}

function toEvent(e: VectorEvent): TaskEvent {
  return {
    id: e.id,
    userId: 'user-1',
    taskId: e.taskId,
    kind: e.kind,
    delta: e.delta ?? undefined,
    occurredAt: e.occurredAt,
    createdAt: e.occurredAt,
    updatedAt: e.occurredAt,
    version: 1,
    isDeleted: e.isDeleted,
  };
}

function runVector(v: Vector): number[] {
  return runSeal(v).cells;
}

function runSeal(v: Vector): SealResult {
  const board = toBoard(v.board);
  const taskById: Record<string, Task> = {};
  for (const t of v.tasks) taskById[t.id] = toTask(t);
  const boardTasks: BoardTask[] = v.boardTasks.map((bt, i) => ({
    id: `bt-${i}`,
    boardId: board.id,
    taskId: bt.taskId,
    row: bt.row,
    col: bt.col,
    createdAt: board.startDate,
    updatedAt: board.startDate,
    version: 1,
    isCenter: false,
    isDeleted: false,
  }));
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of v.events) {
    (eventsByTaskId[e.taskId] ??= []).push(toEvent(e));
  }
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  (v.compoundChildren ?? []).forEach((c, i) => {
    (childrenByCompound[c.compoundTaskId] ??= []).push({
      id: `cc-${i}`,
      compoundTaskId: c.compoundTaskId,
      childTaskId: c.childTaskId,
      childIndex: c.childIndex,
      createdAt: board.startDate,
      updatedAt: board.startDate,
      version: 1,
      isDeleted: c.isDeleted,
    });
  });
  const windowCtx: WindowEvaluationContext = v.sealedAt
    ? boundWindowContextAtSeal(eventsByTaskId, new Date(v.sealedAt).getTime())
    : { eventsByTaskId };
  const cells = computeSealedCompletedCells(
    board,
    boardTasks,
    childrenByCompound,
    taskById,
    [board],
    windowCtx,
  );
  const stats = computeBoardStatsUpdate(
    board,
    boardTasks,
    childrenByCompound,
    taskById,
    [board],
    windowCtx,
  );
  return {
    cells,
    completedTasks: stats.completedTasks,
    linesCompleted: stats.linesCompleted,
    completedLineIds: stats.completedLineIds,
  };
}

describe('computeSealedCompletedCells (fixture-driven, tests/fixtures/sealReDerivationVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const result = runSeal(v);
      expect(result.cells).toEqual(v.expectedCells);
      if (v.expectedCompletedTasks !== undefined) {
        expect(result.completedTasks).toBe(v.expectedCompletedTasks);
      }
      if (v.expectedLinesCompleted !== undefined) {
        expect(result.linesCompleted).toBe(v.expectedLinesCompleted);
      }
      if (v.expectedCompletedLineIds !== undefined) {
        expect(result.completedLineIds).toEqual(v.expectedCompletedLineIds);
      }
    });
  }

  it('Task-4 breadth: compound, 4x4 bingo, and the three sealedAt-bound vectors are all present', () => {
    // Guards against a fixture edit silently dropping a breadth case: the
    // loop above iterates every vector, this pins that the named ones exist.
    const names = new Set(fixture.vectors.map((v) => v.name));
    expect(
      [
        'compound-children-complete-in-window-green-and-pre-window-child-keeps-sibling-compound-grey',
        'bingo-4x4-row-and-main-diagonal-recorded-in-sealed-lines-with-near-misses',
        'normal-completion-after-endDate-before-sealedAt-counts-and-completes-the-row',
        'normal-completion-one-ms-after-sealedAt-excluded-even-though-lifetime-cache-says-done',
        'normal-completion-exactly-at-sealedAt-counts-inclusive-upper-bound',
      ].filter((n) => !names.has(n)),
    ).toEqual([]);
  });

  it('re-derivation is order-independent: shuffling the event union yields the same cells', () => {
    const v = fixture.vectors[0];
    const shuffled: Vector = { ...v, events: [...v.events].reverse() };
    expect(runVector(shuffled)).toEqual(runVector(v));
  });

  it('lifetime default (no window context) is available and returns the center cell for an empty board', () => {
    const board = toBoard(fixture.vectors[0].board);
    const cells = computeSealedCompletedCells(board, [], {}, {}, [], undefined);
    // 3x3 FREE center → index 4 auto-filled.
    expect(cells).toEqual([4]);
  });
});
