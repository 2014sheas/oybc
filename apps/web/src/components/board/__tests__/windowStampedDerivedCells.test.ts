import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  computeBoardGrid,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { taskToSquareData, taskToSquareState, type SquareWindowContext } from '../../../db/adapters';
import { resolveBoardSourceSupply } from '../../../db/operations/boardSources';
import { buildArrivalSquares } from '../../../hooks/useCounterArrivals';
import { buildRisoBoardCells } from '../risoBoardCells';
import { RisoBoardCell } from '../RisoBoardCell';

/**
 * Derived-counter freeze, Task 3 items 4 + 6 — every RENDER / FILTER read of a
 * window-stamped derived counter agrees with the derivation kernel.
 *
 * Owner repro shape: the member's root got logs AFTER the member's window
 * ended, and the one-way propagation latch (`isCompleted`) and lifetime mirror
 * (`currentCount`) both say "complete" — but the kernel (board stats, bingo)
 * says incomplete, because it sums only the root's increments inside the
 * row's own `[startDate, endDate]`. Before this change the play cell, the
 * poster, the compound child row and the Sources done-filter read the latch
 * (green), and the cell's count read `currentCount − baseline` (20/20).
 */

const WS = '2026-09-14T00:00:00.000Z';
const WE = '2026-09-20T23:59:59.999Z';
const ROOT = 'root';

function board(over: Partial<Board> = {}): Board {
  return {
    id: 'wk',
    userId: 'u1',
    name: 'Last week',
    status: BoardStatus.ACTIVE,
    boardSize: 2,
    timeframe: Timeframe.WEEKLY,
    startDate: WS,
    endDate: WE,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 4,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: WS,
    updatedAt: WS,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

function baseTask(over: Partial<Task>): Task {
  return {
    id: 'x',
    userId: 'u1',
    title: 'x',
    type: TaskType.COUNTING,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: WS,
    updatedAt: WS,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

const root = baseTask({ id: ROOT, title: 'Read', action: 'Read', unit: 'pages', maxCount: 80, currentCount: 20 });

/** A window-stamped derived member of ROOT on the `wk` board's window. */
function member(id: string, over: Partial<Task>): Task {
  return baseTask({
    id,
    title: id,
    sharedCounterId: ROOT,
    startDate: WS,
    endDate: WE,
    createdInWizard: true,
    baseline: 0,
    ...over,
  });
}

function inc(id: string, delta: number, occurredAt: string): TaskEvent {
  return {
    id,
    userId: 'u1',
    taskId: ROOT,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

function place(taskId: string, row: number, col: number): BoardTask {
  return {
    id: `bt-${taskId}`,
    boardId: 'wk',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: WS,
    updatedAt: WS,
    version: 1,
    isDeleted: false,
  } as BoardTask;
}

function ctx(events: TaskEvent[]): SquareWindowContext {
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) (eventsByTaskId[e.taskId] ??= []).push(e);
  return { windowStart: WS, eventsByTaskId };
}

// +3 inside the window, +17 three days after it ended (the repro's daily log).
const EVENTS = [inc('in', 3, '2026-09-16T18:00:00.000Z'), inc('late', 17, '2026-09-23T12:00:00.000Z')];

// LATCHED: latch + mirror say 20/20 complete; kernel says 3 of 20.
const latched = member('latched', { maxCount: 20, currentCount: 20, isCompleted: true });
// MET: latch says false, but 3 >= 3 in-window — the kernel says complete.
const met = member('met', { maxCount: 3, currentCount: 0, isCompleted: false });

describe('window-stamped derived cells render what the kernel resolves (items 4 + 6)', () => {
  const tasks = [root, latched, met];
  const taskMap = Object.fromEntries(tasks.map((t) => [t.id, t]));
  const placements = [place('latched', 0, 0), place('met', 0, 1)];

  it('the play-cell state: latched row is incomplete and shows its window sum 3, not 20', () => {
    const state = taskToSquareState(latched, undefined, taskMap, {}, ctx(EVENTS));
    expect(state).toMatchObject({ isCompleted: false, currentCount: 3 });
    // And the latch-false row whose window sum met its target reads complete.
    expect(taskToSquareState(met, undefined, taskMap, {}, ctx(EVENTS))).toMatchObject({
      isCompleted: true,
      currentCount: 3,
    });
  });

  it('poster cells agree with the kernel cell-by-cell, and render the done class only on the met row', () => {
    const b = board();
    const cells = buildRisoBoardCells(b, placements, taskMap, {}, ctx(EVENTS));
    expect(cells.slice(0, 2).map((c) => ({ done: c.done, count: c.count }))).toEqual([
      { done: false, count: { cur: 3, max: 20 } },
      { done: true, count: { cur: 3, max: 3 } },
    ]);

    const kernel = computeBoardGrid(b, placements, {}, taskMap, [b], { eventsByTaskId: ctx(EVENTS).eventsByTaskId });
    expect(kernel.cells.map((c) => [c.taskId, c.isCompleted])).toEqual([
      ['latched', false],
      ['met', true],
    ]);

    // CSS-module classes are hashed (`_done_<hash>`) — match the local name.
    const DONE_CLASS = /class="[^"]*_done_/;
    const latchedHtml = renderToStaticMarkup(React.createElement(RisoBoardCell, { cell: cells[0] }));
    expect(latchedHtml).not.toMatch(DONE_CLASS);
    expect(latchedHtml).toContain('3/20');
    const metHtml = renderToStaticMarkup(React.createElement(RisoBoardCell, { cell: cells[1] }));
    expect(metHtml).toMatch(DONE_CLASS);
  });

  it('a hub-linked member (no startDate) keeps the latch and currentCount − baseline', () => {
    const hub = baseTask({ id: 'hub', sharedCounterId: ROOT, maxCount: 10, baseline: 5, currentCount: 20, isCompleted: true });
    expect(taskToSquareState(hub, undefined, { ...taskMap, hub }, {}, ctx(EVENTS))).toMatchObject({
      isCompleted: true,
      currentCount: 15,
    });
  });

  it('a compound detail sheet child row reads the window-stamped child from root events, not its latch', () => {
    const compound = baseTask({ id: 'cmp', type: TaskType.COMPOUND, operator: OperatorType.AND, maxCount: undefined });
    const links: CompoundChild[] = ['latched', 'met'].map((childTaskId, i) => ({
      id: `cc-${i}`,
      compoundTaskId: 'cmp',
      childTaskId,
      childIndex: i,
      createdAt: WS,
      updatedAt: WS,
      version: 1,
      isDeleted: false,
    })) as CompoundChild[];
    const map = { ...taskMap, cmp: compound };
    const data = taskToSquareData(compound, links, map, { cmp: links }, ctx(EVENTS));
    expect(data.children?.map((c) => [c.taskId, c.isCompleted])).toEqual([
      ['latched', false],
      ['met', true],
    ]);
  });

  it('the Sources done-filter counts only the member the kernel counts', () => {
    const info = resolveBoardSourceSupply(board(), placements, taskMap, ctx(EVENTS).eventsByTaskId);
    expect([...info.doneTaskIds]).toEqual(['met']);
  });

  it('the counter-arrival snapshot reads the same window sum as the cell', () => {
    const squares = buildArrivalSquares({
      boardTasks: placements,
      taskMap,
      sharedCounterSourceIds: new Set([ROOT]),
      windowContext: ctx(EVENTS),
    });
    expect(squares.map((s) => [s.taskId, s.displayed])).toEqual([
      ['latched', 3],
      ['met', 3],
    ]);
  });
});
