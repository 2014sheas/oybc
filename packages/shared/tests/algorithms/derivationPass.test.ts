import * as fs from 'fs';
import * as path from 'path';
import {
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  computeBoardGrid,
  type CellState,
} from '../../src/algorithms/derivationPass';
import { CenterSquareType, TaskType, BoardStatus, Timeframe } from '../../src/constants/enums';
import type {
  Task,
  CompoundChild,
  BoardTask,
  Board,
  TaskEvent,
  WindowEvaluationContext,
} from '../../src';
import type { BoardSize } from '@oybc/bingo-core';

/**
 * C1 (issue #267): fully fixture-driven from
 * `tests/fixtures/derivationPassVectors.json` — the SAME file
 * `apps/ios/OYBCTests/DerivationPassVectorTests.swift` runs through the
 * Swift mirror `DerivationPass` in `Services/DerivationPass.swift`. Pre-C1:
 * 5 `findTransitiveParentCompounds` + 5 `findAffectedBoardIds` + 25
 * `computeBoardStatsUpdate` `it` blocks = 35 total. Post-C1: 5 + 5 + 40
 * fixture vectors — every pre-C1 case has a 1:1 fixture vector, PLUS the
 * fixture generation script (used once during authoring, not checked in)
 * happened to enumerate a couple of extra boundary permutations while
 * cross-checking outputs against the real function, so total vector count
 * is a strict superset of the pre-C1 file.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/derivationPassVectors.json');
const BASE_TS = '2026-04-23T00:00:00.000Z';

interface MiniChild {
  compoundTaskId: string;
  childTaskId: string;
  isDeleted: boolean;
}

interface FtpcVector {
  name: string;
  changedTaskId: string;
  children: MiniChild[];
  expected: string[];
}

interface MiniBoardTaskRef {
  boardId: string;
  taskId: string;
}

interface FabiVector {
  name: string;
  changedTaskId: string;
  parentCompounds: string[];
  boardTasks: MiniBoardTaskRef[];
  expected: string[];
}

interface MiniTask {
  id: string;
  type: string;
  isCompleted: boolean;
  isDeleted: boolean;
  operator: string | null;
  threshold: number | null;
  referencedBoardId: string | null;
  referencedTemplateId: string | null;
  achievementTrigger: string | null;
  requiredCount: number | null;
  /** Optional — carried only by windowed vectors (counting tasks). */
  maxCount?: number | null;
  currentCount?: number | null;
  sharedCounterId?: string | null;
}

/** Minimal event shape for windowed vectors; the consumer fills the
 *  TaskEvent boilerplate (id / userId / timestamps / version). */
interface MiniEvent {
  kind: string;
  occurredAt: string;
  delta?: number;
  isDeleted?: boolean;
}

interface MiniBoardTaskFull {
  taskId: string;
  row: number;
  col: number;
  isDeleted?: boolean;
}

interface MiniBoard {
  id: string;
  boardSize: number;
  centerSquareType: string;
  startDate: string;
  endDate: string | null;
  status: string;
  linesCompleted: number;
  completedLineIds: string[] | null;
  isDeleted: boolean;
  spawnedFromTemplateId: string | null;
}

interface CbsuVector {
  name: string;
  board: MiniBoard;
  boardTasksOnBoard: MiniBoardTaskFull[];
  childrenByCompound: Record<string, MiniChild[]>;
  taskById: Record<string, MiniTask>;
  allBoards: MiniBoard[];
  /** Optional — absent means lifetime resolution (the historical behavior of
   *  every pre-existing vector); present means windowed evaluation against
   *  `board.startDate` via these events (Windowed Completion seam). */
  windowContext?: {
    eventsByTaskId: Record<string, MiniEvent[]>;
  };
  expected: {
    boardId: string;
    completedTasks: number;
    linesCompleted: number;
    completedLineIds: string[];
    newBingos: string[];
    lostBingos: string[];
  };
  /**
   * Board-integrity PR-3 (issue #360) — OPTIONAL per-cell assertions against
   * `computeBoardGrid`'s widened `cells[]` output, pinned for a representative
   * subset of vectors (normal windowed, counting, compound, derived carve-out,
   * achievement board-mode met/unmet, achievement template-mode met/unmet,
   * FREE center — which contributes NO cells entry, only the auto-fill grid
   * bit). Absent on every other (pre-PR-3) vector — `computeBoardStatsUpdate`
   * itself doesn't expose `cells`, so this is checked via a SEPARATE
   * `computeBoardGrid` call below, not by widening `expected`.
   */
  expectedCells?: CellState[];
}

interface Fixture {
  findTransitiveParentCompounds: FtpcVector[];
  findAffectedBoardIds: FabiVector[];
  computeBoardStatsUpdate: CbsuVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

function toChild(m: MiniChild, idx: number): CompoundChild {
  return {
    id: `${m.compoundTaskId}-${m.childTaskId}-${idx}`,
    compoundTaskId: m.compoundTaskId,
    childTaskId: m.childTaskId,
    childIndex: idx,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted,
  };
}

function toBoardTaskRef(m: MiniBoardTaskRef): BoardTask {
  return {
    id: `${m.boardId}-${m.taskId}`,
    boardId: m.boardId,
    taskId: m.taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: false,
  };
}

function toTask(m: MiniTask): Task {
  return {
    id: m.id,
    userId: 'u',
    title: m.id,
    type: m.type as TaskType,
    operator: (m.operator as Task['operator']) ?? undefined,
    threshold: m.threshold ?? undefined,
    referencedBoardId: m.referencedBoardId ?? undefined,
    referencedTemplateId: m.referencedTemplateId ?? undefined,
    achievementTrigger: (m.achievementTrigger as Task['achievementTrigger']) ?? undefined,
    requiredCount: m.requiredCount ?? undefined,
    maxCount: m.maxCount ?? undefined,
    currentCount: m.currentCount ?? undefined,
    sharedCounterId: m.sharedCounterId ?? undefined,
    isCompleted: m.isCompleted,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted,
  };
}

function toBoardTaskFull(m: MiniBoardTaskFull, boardId: string): BoardTask {
  return {
    id: `${boardId}-${m.taskId}`,
    boardId,
    taskId: m.taskId,
    row: m.row,
    col: m.col,
    isCenter: false,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

/** Expand a windowed vector's minimal event into a full TaskEvent row. */
function toEvent(m: MiniEvent, taskId: string, idx: number): TaskEvent {
  return {
    id: `${taskId}-ev-${idx}`,
    userId: 'u',
    taskId,
    kind: m.kind as TaskEvent['kind'],
    delta: m.delta,
    occurredAt: m.occurredAt,
    createdAt: m.occurredAt,
    updatedAt: m.occurredAt,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

/** Build the kernel's WindowEvaluationContext from a vector's minimal shape. */
function toWindowContext(
  wc: CbsuVector['windowContext'],
): WindowEvaluationContext | undefined {
  if (!wc) return undefined;
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const [taskId, events] of Object.entries(wc.eventsByTaskId)) {
    eventsByTaskId[taskId] = events.map((e, idx) => toEvent(e, taskId, idx));
  }
  return { eventsByTaskId };
}

function toBoard(m: MiniBoard): Board {
  return {
    id: m.id,
    userId: 'u',
    name: m.id,
    status: m.status as BoardStatus,
    boardSize: m.boardSize as BoardSize,
    timeframe: Timeframe.MONTHLY,
    startDate: m.startDate,
    endDate: m.endDate ?? undefined,
    centerSquareType: m.centerSquareType as CenterSquareType,
    isRandomized: false,
    totalTasks: m.boardSize * m.boardSize,
    completedTasks: 0,
    linesCompleted: m.linesCompleted,
    completedLineIds: m.completedLineIds ?? undefined,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted,
    spawnedFromTemplateId: m.spawnedFromTemplateId ?? undefined,
  };
}

describe('findTransitiveParentCompounds (fixture-driven, tests/fixtures/derivationPassVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.findTransitiveParentCompounds.length).toBeGreaterThan(0);
  });

  for (const v of fixture.findTransitiveParentCompounds) {
    it(v.name, () => {
      const children = v.children.map(toChild);
      const result = findTransitiveParentCompounds(v.changedTaskId, children);
      expect([...result].sort()).toEqual([...v.expected].sort());
    });
  }
});

describe('findAffectedBoardIds (fixture-driven, tests/fixtures/derivationPassVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.findAffectedBoardIds.length).toBeGreaterThan(0);
  });

  for (const v of fixture.findAffectedBoardIds) {
    it(v.name, () => {
      const boardTasks = v.boardTasks.map(toBoardTaskRef);
      const result = findAffectedBoardIds(v.changedTaskId, new Set(v.parentCompounds), boardTasks);
      expect([...result].sort()).toEqual([...v.expected].sort());
    });
  }
});

describe('computeBoardStatsUpdate (fixture-driven, tests/fixtures/derivationPassVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.computeBoardStatsUpdate.length).toBeGreaterThan(0);
  });

  for (const v of fixture.computeBoardStatsUpdate) {
    it(v.name, () => {
      const board = toBoard(v.board);
      const boardTasksOnBoard = v.boardTasksOnBoard.map((bt) => toBoardTaskFull(bt, board.id));

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const [k, children] of Object.entries(v.childrenByCompound)) {
        childrenByCompound[k] = children.map((c, idx) => toChild(c, idx));
      }

      const taskById: Record<string, Task> = {};
      for (const [k, t] of Object.entries(v.taskById)) taskById[k] = toTask(t);

      const allBoards = v.allBoards.map(toBoard);

      const result = computeBoardStatsUpdate(
        board,
        boardTasksOnBoard,
        childrenByCompound,
        taskById,
        allBoards,
        toWindowContext(v.windowContext),
      );

      expect(result.boardId).toBe(v.expected.boardId);
      expect(result.completedTasks).toBe(v.expected.completedTasks);
      expect(result.linesCompleted).toBe(v.expected.linesCompleted);
      expect(result.completedLineIds).toEqual(v.expected.completedLineIds);
      expect(result.newBingos).toEqual(v.expected.newBingos);
      expect(result.lostBingos).toEqual(v.expected.lostBingos);

      // Board-integrity PR-3 — per-cell `cells[]` assertion, only for vectors
      // that carry `expectedCells`. Calls `computeBoardGrid` directly (NOT
      // `computeBoardStatsUpdate`, whose own return type is unchanged) with
      // the EXACT same inputs, so this also pins that the widened kernel's
      // grid/completedTasks stay byte-identical to computeBoardStatsUpdate's
      // independently-asserted result above.
      if (v.expectedCells) {
        const gridResult = computeBoardGrid(
          board,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
          toWindowContext(v.windowContext),
        );
        expect(gridResult.completedTasks).toBe(v.expected.completedTasks);
        expect(gridResult.cells).toEqual(v.expectedCells);
      }
    });
  }
});
