/**
 * sharedCounterGroups.test.ts — the Counters-Hub / Counter-Detail read model.
 *
 * Verifies grouping over the existing `sharedCounterId` graph: lifetime = source
 * currentCount, per-member derived `logged` via baseline, over-goal, active vs
 * "not counting now" (draft board), orphaned-source skipping, and ordering.
 * The iOS `SharedCounterGroups.swift` port must mirror these cases.
 */

import { buildSharedCounterGroups } from '../../src/algorithms/sharedCounterGroups';
import { BoardStatus, TaskType, Timeframe, CenterSquareType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { Board } from '../../src/types/board';
import type { BoardTask } from '../../src/types/boardTask';

const TS = '2026-02-01T12:00:00.000Z';

interface CounterOpts {
  currentCount?: number;
  maxCount?: number;
  sharedCounterId?: string | null;
  baseline?: number | null;
  timeframe?: Timeframe;
  startDate?: string;
  isDeleted?: boolean;
  title?: string;
  action?: string;
  unit?: string;
}

function counter(id: string, o: CounterOpts = {}): Task {
  return {
    id,
    userId: 'u1',
    title: o.title ?? `Counter ${id}`,
    type: TaskType.COUNTING,
    action: o.action ?? 'Do',
    unit: o.unit ?? 'reps',
    maxCount: o.maxCount,
    currentCount: o.currentCount,
    sharedCounterId: o.sharedCounterId ?? null,
    baseline: o.baseline ?? null,
    timeframe: o.timeframe,
    startDate: o.startDate,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: o.isDeleted ?? false,
  };
}

function board(id: string, status: BoardStatus, timeframe = Timeframe.WEEKLY): Board {
  return {
    id,
    userId: 'u1',
    name: `Board ${id}`,
    status,
    boardSize: 5,
    timeframe,
    startDate: TS,
    endDate: '2026-02-07T12:00:00.000Z',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: false,
  };
}

function placement(taskId: string, boardId: string): BoardTask {
  return {
    id: `bt-${taskId}-${boardId}`,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
  };
}

describe('buildSharedCounterGroups', () => {
  it('returns [] when there are no shared-counter links', () => {
    const tasks = [counter('a', { currentCount: 5 })]; // standalone, no link
    const groups = buildSharedCounterGroups({ tasks, boardTasks: [], boards: [] });
    expect(groups).toEqual([]);
  });

  it('groups a source + one inherit-baseline derived task', () => {
    const src = counter('src', { title: 'Push-ups', currentCount: 512, maxCount: 1000 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 30 });
    const bWeekly = board('bw', BoardStatus.ACTIVE, Timeframe.WEEKLY);
    const bMonthly = board('bm', BoardStatus.ACTIVE, Timeframe.MONTHLY);

    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [placement('src', 'bm'), placement('der', 'bw')],
      boards: [bWeekly, bMonthly],
    });

    expect(groups).toHaveLength(1);
    const g = groups[0];
    expect(g.counterId).toBe('src');
    expect(g.name).toBe('Push-ups');
    expect(g.lifetime).toBe(512);
    expect(g.taskCount).toBe(2);
    expect(g.boardCount).toBe(2);
    expect(g.activeTaskCount).toBe(2);

    // Source first, baseline 0 → displayed = lifetime (512), goal 1000 → not met.
    const source = g.tasks[0];
    expect(source.isSource).toBe(true);
    expect(source.logged).toBe(512);
    expect(source.goal).toBe(1000);
    expect(source.met).toBe(false);
    expect(source.boardName).toBe('Board bm');

    // Derived inherit (baseline 0) → displayed = 512, goal 30 → met, 482 over.
    const derived = g.tasks[1];
    expect(derived.isSource).toBe(false);
    expect(derived.logged).toBe(512);
    expect(derived.goal).toBe(30);
    expect(derived.met).toBe(true);
    expect(derived.over).toBe(482);
  });

  it('applies start-from-zero baseline to the derived logged value', () => {
    const src = counter('src', { currentCount: 100 });
    // Linked when source was at 70 → baseline 70 → displayed = 100 - 70 = 30.
    const der = counter('der', { sharedCounterId: 'src', baseline: 70, maxCount: 50 });
    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [],
      boards: [],
    });
    const derived = groups[0].tasks.find((t) => t.taskId === 'der')!;
    expect(derived.logged).toBe(30);
    expect(derived.goal).toBe(50);
    expect(derived.met).toBe(false);
  });

  it('clamps a derived value to 0 (never negative) when baseline exceeds count', () => {
    const src = counter('src', { currentCount: 20 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 50, maxCount: 10 });
    const groups = buildSharedCounterGroups({ tasks: [src, der], boardTasks: [], boards: [] });
    const derived = groups[0].tasks.find((t) => t.taskId === 'der')!;
    expect(derived.logged).toBe(0);
    expect(derived.met).toBe(false);
    expect(derived.over).toBe(0);
  });

  it('marks a task on a DRAFT board as not-counting (inactive)', () => {
    const src = counter('src', { currentCount: 40 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 30 });
    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [placement('src', 'active'), placement('der', 'draft')],
      boards: [board('active', BoardStatus.ACTIVE), board('draft', BoardStatus.DRAFT)],
    });
    const g = groups[0];
    expect(g.activeTaskCount).toBe(1);
    expect(g.tasks.find((t) => t.taskId === 'der')!.isActive).toBe(false);
    expect(g.tasks.find((t) => t.taskId === 'src')!.isActive).toBe(true);
  });

  it('skips an orphaned group whose source task is deleted', () => {
    const src = counter('src', { currentCount: 5, isDeleted: true });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 3 });
    const groups = buildSharedCounterGroups({ tasks: [src, der], boardTasks: [], boards: [] });
    expect(groups).toEqual([]);
  });

  it('excludes deleted linked tasks from the member list', () => {
    const src = counter('src', { currentCount: 10 });
    const der1 = counter('der1', { sharedCounterId: 'src', baseline: 0, maxCount: 5 });
    const der2 = counter('der2', { sharedCounterId: 'src', baseline: 0, maxCount: 5, isDeleted: true });
    const groups = buildSharedCounterGroups({ tasks: [src, der1, der2], boardTasks: [], boards: [] });
    expect(groups[0].taskCount).toBe(2); // source + der1 only
    expect(groups[0].tasks.map((t) => t.taskId).sort()).toEqual(['der1', 'src']);
  });

  it('gives a member with no live board placement a null board and inactive', () => {
    const src = counter('src', { currentCount: 10 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 5 });
    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [placement('src', 'b1')],
      boards: [board('b1', BoardStatus.ACTIVE)],
    });
    const derived = groups[0].tasks.find((t) => t.taskId === 'der')!;
    expect(derived.boardId).toBeNull();
    expect(derived.boardName).toBeNull();
    expect(derived.isActive).toBe(false);
  });

  it('counts distinct boards for boardCount, not placements', () => {
    const src = counter('src', { currentCount: 10 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 5 });
    // Both members primarily resolve to the same board.
    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [placement('src', 'b1'), placement('der', 'b1')],
      boards: [board('b1', BoardStatus.ACTIVE)],
    });
    expect(groups[0].boardCount).toBe(1);
  });

  it('sorts groups by counter name, case-insensitively', () => {
    const zSrc = counter('z', { title: 'zebra', currentCount: 1 });
    const zDer = counter('zd', { sharedCounterId: 'z', baseline: 0, maxCount: 1 });
    const aSrc = counter('a', { title: 'Apple', currentCount: 1 });
    const aDer = counter('ad', { sharedCounterId: 'a', baseline: 0, maxCount: 1 });
    const groups = buildSharedCounterGroups({
      tasks: [zSrc, zDer, aSrc, aDer],
      boardTasks: [],
      boards: [],
    });
    expect(groups.map((g) => g.name)).toEqual(['Apple', 'zebra']);
  });

  it('prefers an ACTIVE board as a task primary placement over a draft', () => {
    const src = counter('src', { currentCount: 10, maxCount: 5 });
    const der = counter('der', { sharedCounterId: 'src', baseline: 0, maxCount: 5 });
    const groups = buildSharedCounterGroups({
      tasks: [src, der],
      boardTasks: [placement('src', 'draft'), placement('src', 'active')],
      boards: [board('draft', BoardStatus.DRAFT), board('active', BoardStatus.ACTIVE)],
    });
    const source = groups[0].tasks.find((t) => t.taskId === 'src')!;
    expect(source.boardId).toBe('active');
    expect(source.isActive).toBe(true);
  });
});
