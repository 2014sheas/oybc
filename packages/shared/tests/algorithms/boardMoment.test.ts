import * as fs from 'fs';
import * as path from 'path';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type OperatorType } from '../../src/constants/enums';
import type { Board } from '../../src/types/board';
import type { BoardTask } from '../../src/types/boardTask';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import type { TaskEvent } from '../../src/types/taskEvent';
import {
  computeBoardMomentReplay,
  momentCellVisual,
  momentCounterAt,
  momentFinalBeat,
  momentPosterCells,
  type BoardMomentReplay,
  type MomentKind,
} from '../../src/algorithms/boardMoment';
import { computeBoardGrid } from '../../src/algorithms/derivationPass';
import { boundWindowContextAtSeal } from '../../src/algorithms/taskEvents';
import { detectBingos } from '@oybc/bingo-core';

/**
 * Vector pins for `boardMoment.ts` <-> iOS `BoardMoment.swift`
 * (`BoardMomentVectorTests`) - docs/BOARD_MOMENTS.md.
 */

const V = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'boardMomentVectors.json'), 'utf8'));

const T0 = '2026-01-01T00:00:00.000Z';

interface MiniBoard {
  id: string;
  size: number;
  centerSquareType: string;
  startDate: string;
  endDate: string;
  completedTasks: number;
  completedLineIds?: string[];
  sealedAt?: string;
  sealedCompletedCells?: number[];
  status?: string;
  linesCompleted?: number;
  totalTasks?: number;
}

function toBoard(m: MiniBoard): Board {
  return {
    id: m.id,
    userId: 'u',
    name: m.id,
    status: (m.status as BoardStatus) ?? BoardStatus.ACTIVE,
    boardSize: m.size as Board['boardSize'],
    timeframe: Timeframe.CUSTOM,
    startDate: m.startDate,
    endDate: m.endDate,
    centerSquareType: m.centerSquareType as CenterSquareType,
    isRandomized: false,
    totalTasks: m.totalTasks ?? m.size * m.size,
    completedTasks: m.completedTasks,
    linesCompleted: m.linesCompleted ?? (m.completedLineIds ?? []).length,
    completedLineIds: m.completedLineIds,
    sealedAt: m.sealedAt,
    sealedCompletedCells: m.sealedCompletedCells,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

function toTask(m: { id: string; type?: string; operator?: string; maxCount?: number; referencedBoardId?: string; achievementTrigger?: string; isCompleted?: boolean; completedAt?: string; sharedCounterId?: string; startDate?: string; endDate?: string; createdInWizard?: boolean }): Task {
  return {
    id: m.id,
    userId: 'u',
    title: m.id,
    type: (m.type as TaskType) ?? TaskType.NORMAL,
    operator: m.operator as OperatorType | undefined,
    maxCount: m.maxCount,
    referencedBoardId: m.referencedBoardId,
    achievementTrigger: m.achievementTrigger as Task['achievementTrigger'],
    isCompleted: m.isCompleted ?? false,
    completedAt: m.completedAt,
    sharedCounterId: m.sharedCounterId,
    startDate: m.startDate,
    endDate: m.endDate,
    createdInWizard: m.createdInWizard,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

function group<T>(rows: T[], key: keyof T): Record<string, T[]> {
  const out: Record<string, T[]> = {};
  for (const r of rows) (out[r[key] as unknown as string] ??= []).push(r);
  return out;
}

interface Built {
  board: Board;
  boardTasks: BoardTask[];
  childrenByCompound: Record<string, CompoundChild[]>;
  taskById: Record<string, Task>;
  eventsByTaskId: Record<string, TaskEvent[]>;
  allBoards: Board[];
}

function build(c: any): Built {
  const tasks: Task[] = c.tasks.map(toTask);
  const events: TaskEvent[] = c.events.map((e: any, i: number) => ({
    id: e.id ?? `e${i}`,
    userId: 'u',
    taskId: e.taskId,
    kind: e.delta !== undefined ? 'increment' : 'completion',
    delta: e.delta,
    occurredAt: e.occurredAt,
    createdAt: e.occurredAt,
    updatedAt: e.occurredAt,
    version: 1,
    isDeleted: false,
  }));
  const children: CompoundChild[] = (c.children ?? []).map((r: any, i: number) => ({
    id: `l${i}`,
    compoundTaskId: r.compoundTaskId,
    childTaskId: r.childTaskId,
    childIndex: i,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  }));
  const boardTasks: BoardTask[] = c.boardTasks.map((b: any) => ({
    id: b.id,
    boardId: c.board.id,
    taskId: b.taskId,
    row: b.row,
    col: b.col,
    isDeleted: b.isDeleted ?? false,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
  }));
  return {
    board: toBoard(c.board),
    boardTasks,
    childrenByCompound: group(children, 'compoundTaskId'),
    taskById: Object.fromEntries(tasks.map((t) => [t.id, t])),
    eventsByTaskId: group(events, 'taskId'),
    allBoards: (c.allBoards ?? []).map((b: any) => toBoard({ ...b, size: 3, centerSquareType: 'free' })),
  };
}

const replayOf = (b: Built): BoardMomentReplay =>
  computeBoardMomentReplay(b.board, b.boardTasks, b.childrenByCompound, b.taskById, b.eventsByTaskId, b.allBoards);

describe('boardMomentVectors.json', () => {
  for (const c of V.cases) {
    describe(c.name, () => {
      const built = build(c);
      const replay = replayOf(built);

      it('replay matches expected (order, freeIdx, closure beats, rail numbers)', () => {
        const { finalBeat, ...rest } = c.expected;
        expect(replay).toEqual(rest);
        expect(momentFinalBeat(replay, 'bingo')).toBe(finalBeat.bingo);
        expect(momentFinalBeat(replay, 'greenlog')).toBe(finalBeat.greenlog);
      });

      it('FREE never lands and is never in order', () => {
        if (replay.freeIdx !== null) {
          expect(replay.order.some((e) => e.idx === replay.freeIdx)).toBe(false);
          for (let beat = 0; beat <= 20; beat++) {
            expect(momentCellVisual(replay.freeIdx, beat, replay, 'bingo').landed).toBe(false);
          }
        }
      });

      it('end state equals the play grid (live) or the sealed snapshot', () => {
        const total = replay.size * replay.size;
        const finalBeat = momentFinalBeat(replay, 'bingo');
        const landed = new Set<number>();
        for (let i = 0; i < total; i++) if (momentCellVisual(i, finalBeat, replay, 'bingo').landed) landed.add(i);
        const expected = new Set<number>();
        if (built.board.sealedAt) {
          for (const i of built.board.sealedCompletedCells ?? []) {
            const bt = built.boardTasks.find((b) => b.row * replay.size + b.col === i);
            if (i !== replay.freeIdx && bt && built.taskById[bt.taskId]) expected.add(i);
          }
        } else {
          const events = built.eventsByTaskId;
          const { grid } = computeBoardGrid(built.board, built.boardTasks, built.childrenByCompound, built.taskById, built.allBoards, { eventsByTaskId: events });
          grid.forEach((done, i) => { if (done && i !== replay.freeIdx) expected.add(i); });
        }
        expect(landed).toEqual(expected);
        expect(momentCounterAt(finalBeat, replay)).toBe(built.board.completedTasks);
        if (!built.board.sealedAt) {
          const endGrid = new Array(total).fill(false);
          for (const i of landed) endGrid[i] = true;
          if (replay.freeIdx !== null) endGrid[replay.freeIdx] = true;
          expect(Object.keys(replay.lineClosureBeat).sort()).toEqual(
            detectBingos(endGrid, replay.size as 3 | 4 | 5).completedLines.sort(),
          );
        }
      });

      for (const f of c.frames) {
        it(`${f.kind} frame at beat ${f.beat}`, () => {
          const landed: number[] = [];
          const green: number[] = [];
          const popTokens: Record<string, number> = {};
          for (let i = 0; i < replay.size * replay.size; i++) {
            const v = momentCellVisual(i, f.beat, replay, f.kind as MomentKind);
            if (v.landed) landed.push(i);
            if (v.green) green.push(i);
            if (v.popToken !== null) popTokens[String(i)] = v.popToken;
          }
          expect({ counter: momentCounterAt(f.beat, replay), landed, green, popTokens }).toEqual({
            counter: f.counter, landed: f.landed, green: f.green, popTokens: f.popTokens,
          });
        });
      }
    });
  }
});

describe('boardMoment edge cases', () => {
  const c = V.cases[0];

  it('a sealed board bounds events at sealedAt before resolving instants', () => {
    const built = build(V.cases.find((x: any) => x.name === 'sealed-set-wins'));
    const bounded = boundWindowContextAtSeal(built.eventsByTaskId, new Date(built.board.sealedAt as string).getTime()).eventsByTaskId;
    expect(bounded['t1']).toBeUndefined();
    expect(replayOf(built).order.find((e) => e.idx === 1)?.completedAt).toBeNull();
  });

  it('a board with no completed cells has an empty order and counter at the rail value', () => {
    const built = build(c);
    built.eventsByTaskId = {};
    built.board = { ...built.board, completedTasks: 1, completedLineIds: [] };
    const replay = replayOf(built);
    expect(replay.order).toEqual([]);
    expect(replay.lineClosureBeat).toEqual({});
    expect(momentFinalBeat(replay, 'bingo')).toBe(0);
    expect(momentCounterAt(0, replay)).toBe(1);
    expect(momentCounterAt(99, replay)).toBe(1);
  });

  it('the counter never goes negative when the rail counts fewer cells than landed', () => {
    const replay: BoardMomentReplay = {
      order: [{ boardTaskId: 'a', idx: 0, completedAt: null }, { boardTaskId: 'b', idx: 1, completedAt: null }],
      freeIdx: null, lineClosureBeat: {}, completedTasks: 1, totalTasks: 9, size: 3,
    };
    expect(momentCounterAt(0, replay)).toBe(0);
    expect(momentCounterAt(-4, replay)).toBe(0);
  });

  it('a sealed cell with no placement is skipped, not invented', () => {
    const built = build(V.cases.find((x: any) => x.name === 'sealed-set-wins'));
    built.board = { ...built.board, sealedCompletedCells: [0, 1, 2, 4, 7, 99, -1] };
    built.boardTasks = built.boardTasks.filter((bt) => bt.row * 3 + bt.col !== 7);
    expect(replayOf(built).order.map((e) => e.idx)).toEqual([0, 1, 2]);
  });
});

describe('momentPosterCells vectors', () => {
  for (const c of V.posterCells) {
    it(c.name, () => {
      expect(momentPosterCells(c.replay as BoardMomentReplay, c.cells, c.kind as MomentKind)).toEqual(c.expected);
    });
  }

  it('is the final-beat frame of momentCellVisual for every cell', () => {
    for (const c of V.posterCells) {
      const final = momentFinalBeat(c.replay, c.kind);
      for (const cell of momentPosterCells(c.replay, c.cells, c.kind)) {
        const v = momentCellVisual(cell.idx, final, c.replay, c.kind);
        expect(cell.state).toBe(v.green ? 'green' : v.landed ? 'done' : 'undone');
      }
    }
  });

  it('keeps the input order and length, and adds nothing else', () => {
    const c = V.posterCells[0];
    const out = momentPosterCells(c.replay, [...c.cells].reverse(), c.kind);
    expect(out.map((x) => x.idx)).toEqual([...c.cells].reverse().map((x: any) => x.idx));
    expect(Object.keys(out[0]).sort()).toEqual(['idx', 'isFree', 'label', 'state', 'type']);
  });
});
