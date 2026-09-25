import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { buildSquareWindowContext, taskToSquareData, taskToSquareState } from '../adapters';
import { buildBoardPreviewCells } from '../../components/home/boardPreviewCells';

/**
 * 2026-09-24 amendment of WC Decision 1 — the play-cell read path. An ENDED
 * board's squares resolve against `[startDate, endDate]`: increments / child
 * completions logged after `endDate` (today, on the next window's board) must
 * not raise the ended board's displayed count or green its cell. The pure
 * adapters (`buildSquareWindowContext` → `taskToSquareState` /
 * `taskToSquareData`) are exactly what `useBoardPlayData` /
 * `useSquareWindowContext` feed the play grid, and `buildBoardPreviewCells`
 * builds the same context from the board itself.
 */

const START = '2026-09-22T00:00:00.000';
const END = '2026-09-22T23:59:59.999';
const IN_WINDOW = new Date('2026-09-22T09:00:00.000').toISOString();
const AFTER_END = new Date('2026-09-23T08:00:00.000').toISOString();

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function event(id: string, taskId: string, occurredAt: string, over: Partial<TaskEvent> = {}): TaskEvent {
  return {
    id,
    userId: 'user-1',
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

// Counting goal 5: +3 inside the window, +2 after its end (lifetime cache says 5 / complete).
const COUNTER = task('k', { type: TaskType.COUNTING, maxCount: 5, currentCount: 5, isCompleted: true });
const COUNTER_EVENTS = [
  event('k1', 'k', IN_WINDOW, { kind: 'increment', delta: 3 }),
  event('k2', 'k', AFTER_END, { kind: 'increment', delta: 2 }),
];

describe('SquareWindowContext carries the board end bound', () => {
  it('buildSquareWindowContext records windowEnd', () => {
    expect(buildSquareWindowContext([], START, END).windowEnd).toBe(END);
    expect(buildSquareWindowContext([], START, null).windowEnd).toBeNull();
  });

  it('a counting cell on an ended board ignores increments after endDate', () => {
    const state = taskToSquareState(COUNTER, undefined, undefined, undefined, buildSquareWindowContext(COUNTER_EVENTS, START, END));
    expect(state.currentCount).toBe(3);
    expect(state.isCompleted).toBe(false);
  });

  it('an indefinite board (windowEnd null) still counts every event from startDate (control)', () => {
    const state = taskToSquareState(COUNTER, undefined, undefined, undefined, buildSquareWindowContext(COUNTER_EVENTS, START, null));
    expect(state.currentCount).toBe(5);
    expect(state.isCompleted).toBe(true);
  });

  it('a compound cell (and its detail-sheet child row) ignores a child completed after endDate', () => {
    const parent = task('p', { type: TaskType.COMPOUND, operator: OperatorType.AND });
    const c1 = task('c1', { isCompleted: true });
    const c2 = task('c2', { isCompleted: true });
    const links: CompoundChild[] = ['c1', 'c2'].map((childTaskId, i) => ({
      id: `link-${childTaskId}`,
      compoundTaskId: 'p',
      childTaskId,
      childIndex: i,
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    }));
    const taskMap = { p: parent, c1, c2 };
    const cb = { p: links };
    const ctx = buildSquareWindowContext(
      [event('e1', 'c1', IN_WINDOW), event('e2', 'c2', AFTER_END)],
      START,
      END,
    );
    expect(taskToSquareState(parent, links, taskMap, cb, ctx).isCompleted).toBe(false);
    const data = taskToSquareData(parent, links, taskMap, cb, ctx);
    expect(data.children?.map((c) => c.isCompleted)).toEqual([true, false]);
  });
});

describe('buildBoardPreviewCells bounds an ended board at its endDate', () => {
  it('a counting square whose goal is met only after endDate previews incomplete', () => {
    const board: Board = {
      id: 'b',
      userId: 'user-1',
      name: 'Yesterday',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      endDate: END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    const bt: BoardTask = {
      id: 'bt',
      boardId: 'b',
      taskId: 'k',
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    const { cells } = buildBoardPreviewCells(board, [bt], { k: COUNTER }, {}, { k: COUNTER_EVENTS });
    expect(cells[0]).toEqual({ kind: 'task', completed: false });
  });
});
