import * as fs from 'fs';
import * as path from 'path';
import { computeSealedCompletedCells } from '../../src/algorithms/derivationPass';
import type { WindowEvaluationContext } from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, Board, BoardTask } from '../../src/types';
import { TaskType, Timeframe, BoardStatus, CenterSquareType } from '../../src/constants/enums';

/**
 * sealReDerivation.test.ts — Windowed Completion PR A seal-snapshot builder
 * (docs/WINDOWED_COMPLETION.md §Seal snapshots re-derive from the event union).
 * Fixture-driven from `tests/fixtures/sealReDerivationVectors.json` — the SAME
 * file the deferred iOS seal-re-derivation vectors (PR C) will run. Property:
 * the green cell set is a pure function of the converged in-window event union,
 * so the same union (any order) yields the same cells on any device.
 */

interface VectorBoard {
  id: string;
  boardSize: number;
  centerSquareType: string;
  startDate: string;
  endDate: string;
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
  isCompleted: boolean;
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
  expectedCells: number[];
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
    endDate: b.endDate,
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
  }));
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of v.events) {
    (eventsByTaskId[e.taskId] ??= []).push(toEvent(e));
  }
  const windowCtx: WindowEvaluationContext = { eventsByTaskId };
  return computeSealedCompletedCells(board, boardTasks, {}, taskById, [], windowCtx);
}

describe('computeSealedCompletedCells (fixture-driven, tests/fixtures/sealReDerivationVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      expect(runVector(v)).toEqual(v.expectedCells);
    });
  }

  it('re-derivation is order-independent: shuffling the event union yields the same cells', () => {
    const v = fixture.vectors[0];
    const shuffled: Vector = { ...v, events: [...v.events].reverse() };
    expect(runVector(shuffled)).toEqual(runVector(v));
  });

  it('lifetime default (no window context) is available and returns the center cell for an empty board', () => {
    const board = toBoard(fixture.vectors[0].board);
    const cells = computeSealedCompletedCells(board, [], {}, {});
    // 3x3 FREE center → index 4 auto-filled.
    expect(cells).toEqual([4]);
  });
});
