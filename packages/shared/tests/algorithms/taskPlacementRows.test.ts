import * as fs from 'fs';
import * as path from 'path';
import { placementsReachedByTasks } from '../../src/algorithms/derivationPass';
import { taskPlacementRows } from '../../src/algorithms/taskPlacementRows';
import type { Board } from '../../src/types/board';
import type { BoardTask } from '../../src/types/boardTask';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import type { TaskEvent } from '../../src/types/taskEvent';

/**
 * Task Detail PR 5 — `taskPlacementRows`, pinned by
 * `tests/fixtures/taskPlacementRowsVectors.json` (iOS twin:
 * `TaskPlacementRowsVectorTests.swift`). Defaults per the fixture's notes.
 */
const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/taskPlacementRowsVectors.json'), 'utf8'),
) as { vectors: Array<Record<string, any>> };

const T0 = '2026-10-01T00:00:00.000Z';

function build(v: Record<string, any>) {
  const tasks: Task[] = v.tasks.map((t: any) => ({
    userId: 'u', title: t.id, isCompleted: false, isDeleted: false, version: 1, createdAt: T0, updatedAt: T0,
    totalCompletions: 0, totalInstances: 0, ...t,
  }));
  const boards: Board[] = v.boards.map((b: any) => ({
    userId: 'u', name: b.id, status: 'active', boardSize: 3, timeframe: 'weekly', centerSquareType: 'none',
    isRandomized: false, isDeleted: false, totalTasks: 9, completedTasks: 0, linesCompleted: 0,
    createdAt: T0, updatedAt: T0, version: 1, ...b,
  }));
  const boardTasks: BoardTask[] = v.boardTasks.map((bt: any) => ({
    isCenter: false, isDeleted: false, createdAt: T0, updatedAt: T0, version: 1, ...bt,
  }));
  const index: Record<string, number> = {};
  const links: CompoundChild[] = v.links.map((l: any) => {
    const childIndex = index[l.compoundTaskId] ?? 0;
    index[l.compoundTaskId] = childIndex + 1;
    return { userId: 'u', childIndex, isDeleted: false, createdAt: T0, updatedAt: T0, version: 1, ...l };
  });
  const events: TaskEvent[] = v.events.map((e: any, i: number) => ({
    id: `e${i}`, userId: 'u', kind: 'increment', isDeleted: false, createdAt: e.occurredAt, updatedAt: e.occurredAt, version: 1, ...e,
  }));
  const group = <X,>(xs: X[], key: (x: X) => string): Record<string, X[]> => {
    const out: Record<string, X[]> = {};
    for (const x of xs) (out[key(x)] ??= []).push(x);
    return out;
  };
  const reach = placementsReachedByTasks([v.taskId], { tasks, compoundChildren: links, boardTasks });
  return taskPlacementRows({
    taskId: v.taskId,
    reach: reach.placements,
    boardsById: Object.fromEntries(boards.map((b) => [b.id, b])),
    taskById: Object.fromEntries(tasks.map((t) => [t.id, t])),
    childrenByCompound: group(links, (l) => l.compoundTaskId),
    eventsByTaskId: group(events, (e) => e.taskId),
    boardTasksByBoard: group(boardTasks.filter((bt) => !bt.isDeleted), (bt) => bt.boardId),
    allBoards: boards,
  });
}

describe('taskPlacementRows — shared vectors', () => {
  it('covers the fixture', () => {
    expect(fixture.vectors.length).toBe(13);
  });
  for (const v of fixture.vectors) {
    it(v.name, () => {
      expect(build(v)).toEqual(v.expected);
    });
  }
});
