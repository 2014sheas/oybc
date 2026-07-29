import { describe, expect, it } from 'vitest';
import {
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
import { buildRisoBoardCells } from '../RisoBoard';

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
