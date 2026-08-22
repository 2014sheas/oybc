import { describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  CenterSquareType,
  TaskType,
  Timeframe,
  BoardStatus,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import type { SquareWindowContext } from '../../../db/adapters';
import { buildRisoBoardCells } from '../risoBoardCells';

/**
 * Issue #376 — the Home ResumePanel poster (`RisoBoard`) must treat a sealed
 * board as a frozen record: cells from `sealedCompletedCells`, rings from the
 * frozen `completedLineIds` — never live event derivation. A sealed board can
 * still be status ACTIVE (sealed-incomplete keeps ACTIVE forever), which is
 * exactly how it reaches Home's ACTIVE filter.
 */

const WINDOW_START = '2026-07-01T00:00:00.000Z';

function makeBoard(over: Partial<Board> = {}): Board {
  return {
    id: 'b1',
    userId: 'u1',
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 2,
    timeframe: Timeframe.MONTHLY,
    startDate: WINDOW_START,
    endDate: '2026-07-31T23:59:59.999Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 4,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

function makeTask(id: string): Task {
  return {
    id,
    userId: 'u1',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
  } as Task;
}

function place(taskId: string, row: number, col: number): BoardTask {
  return {
    id: `bt-${taskId}`,
    boardId: 'b1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
  } as BoardTask;
}

function completion(taskId: string, occurredAt: string): TaskEvent {
  return {
    id: `ev-${taskId}`,
    userId: 'u1',
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

const tasks = ['t0', 't1', 't2', 't3'].map(makeTask);
const taskMap = Object.fromEntries(tasks.map((t) => [t.id, t]));
const placements = [place('t0', 0, 0), place('t1', 0, 1), place('t2', 1, 0), place('t3', 1, 1)];

function ctx(events: TaskEvent[]): SquareWindowContext {
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) (eventsByTaskId[e.taskId] ??= []).push(e);
  return { windowStart: WINDOW_START, eventsByTaskId };
}

describe('buildRisoBoardCells — sealed vs live (issue #376)', () => {
  it('live board: cells resolve windowed from events', () => {
    const cells = buildRisoBoardCells(
      makeBoard(),
      placements,
      taskMap,
      {},
      ctx([completion('t0', '2026-07-10T00:00:00.000Z')]),
    );
    expect(cells.map((c) => c.done)).toEqual([true, false, false, false]);
  });

  it('sealed board: cells come from the frozen snapshot, ignoring live events', () => {
    // Live events say t0 is complete; the frozen record says cells 1 and 3.
    const sealed = makeBoard({
      sealedAt: '2026-08-01T02:00:00.000Z',
      sealedCompletedCells: [1, 3],
      completedLineIds: [],
    });
    const cells = buildRisoBoardCells(
      sealed,
      placements,
      taskMap,
      {},
      ctx([completion('t0', '2026-07-10T00:00:00.000Z')]),
    );
    expect(cells.map((c) => c.done)).toEqual([false, true, false, true]);
  });

  it('sealed board: rings come from the frozen completedLineIds, not live detection', () => {
    // The frozen snapshot has the top row complete + its line recorded.
    const sealed = makeBoard({
      sealedAt: '2026-08-01T02:00:00.000Z',
      sealedCompletedCells: [0, 1],
      completedLineIds: ['row_0'],
    });
    const cells = buildRisoBoardCells(sealed, placements, taskMap, {}, ctx([]));
    expect(cells.map((c) => c.isLine)).toEqual([true, true, false, false]);
  });

  it('sealed board: a counting cell freezes its displayed count (done → max, else 0)', () => {
    // Post-seal increments on a shared task must not animate a frozen poster
    // (review finding on #381; mirrors BoardPlaySurface's taskCurrentCount).
    const counter = {
      ...makeTask('t0'),
      type: TaskType.COUNTING,
      maxCount: 5,
      currentCount: 7,
    } as Task;
    const map = { ...taskMap, t0: counter };
    const sealed = makeBoard({
      sealedAt: '2026-08-01T02:00:00.000Z',
      sealedCompletedCells: [0],
      completedLineIds: [],
    });
    const events = [
      { id: 'inc', userId: 'u1', taskId: 't0', kind: 'increment', delta: 3, occurredAt: '2026-08-05T00:00:00.000Z', createdAt: '2026-08-05T00:00:00.000Z', updatedAt: '2026-08-05T00:00:00.000Z', version: 1, isDeleted: false } as TaskEvent,
    ];
    const cells = buildRisoBoardCells(sealed, placements, map, {}, ctx(events));
    expect(cells[0].count).toEqual({ cur: 5, max: 5 });

    const sealedIncomplete = makeBoard({
      sealedAt: '2026-08-01T02:00:00.000Z',
      sealedCompletedCells: [],
      completedLineIds: [],
    });
    const cells2 = buildRisoBoardCells(sealedIncomplete, placements, map, {}, ctx(events));
    expect(cells2[0].count).toEqual({ cur: 0, max: 5 });
  });

  it('sealed-but-ACTIVE board (the Home leak shape) still reads the snapshot', () => {
    const sealed = makeBoard({
      status: BoardStatus.ACTIVE,
      sealedAt: '2026-08-01T02:00:00.000Z',
      sealedCompletedCells: [],
      completedLineIds: [],
    });
    // A post-seal live event on a placed task must NOT paint the poster.
    const cells = buildRisoBoardCells(
      sealed,
      placements,
      taskMap,
      {},
      ctx([completion('t2', '2026-08-05T00:00:00.000Z')]),
    );
    expect(cells.every((c) => !c.done && !c.isLine)).toBe(true);
  });
});

/**
 * board-integrity PR-3 (#360, finding 2): the RisoBoard poster must resolve an
 * ACHIEVEMENT square's completion from the cross-board kernel pass, not the
 * always-false plain-task fallback. This renderer originally missed that fix
 * (it called taskToSquareState with no cellState), so achievement squares on
 * the Home "Jump back in" poster always showed incomplete + broke bingo rings.
 */
describe('buildRisoBoardCells — ACHIEVEMENT squares resolve cross-board (#360)', () => {
  const achievement = {
    ...makeTask('ach'),
    type: TaskType.ACHIEVEMENT,
    achievementTrigger: AchievementTrigger.GREENLOG,
    referencedBoardId: 'watched',
  } as Task;

  it('resolves an achievement square DONE when its referenced board is greenlogged', () => {
    const board = makeBoard({ id: 'b1', boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const watched = makeBoard({ id: 'watched', status: BoardStatus.COMPLETED });
    const cells = buildRisoBoardCells(
      board,
      [place('ach', 0, 0)],
      { ach: achievement },
      {},
      ctx([]),
      [board, watched],
    );
    expect(cells[0].done).toBe(true);
  });

  it('degrades to not-done (never crashes) when allBoards is omitted', () => {
    const board = makeBoard({ id: 'b1', boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const cells = buildRisoBoardCells(board, [place('ach', 0, 0)], { ach: achievement }, {}, ctx([]));
    expect(cells[0].done).toBe(false);
  });
});
