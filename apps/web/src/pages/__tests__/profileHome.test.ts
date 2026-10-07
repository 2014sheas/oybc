import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  BoardSize,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type SharedCounterGroup,
  type SharedCounterMemberTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import {
  buildBoardSettingsTileSummary,
  buildStreakTileData,
  formatLastLoggedLabel,
  lastLoggedTimestamp,
  selectMostRecentlyLoggedMember,
  selectRecentCounters,
} from '../profileHome';

/**
 * profileHome.test.ts — Vitest coverage for the pure helpers behind the new
 * Profile home (`pages/ProfilePage.tsx`, Profile reorg PR2). The hook
 * (`hooks/useProfileHome.ts`) and DB layer are intentionally untested here;
 * see `db/operations/__tests__` for shared-counter write-path coverage this
 * page reuses (`incrementSharedCounter`, `undoLastCounterLog`).
 */

const CREATED = '2026-01-01T00:00:00.000Z';

function makeBoard(id: string, over: Partial<Board> = {}): Board {
  return {
    id,
    userId: 'user-1',
    name: `Board ${id}`,
    status: BoardStatus.ACTIVE,
    boardSize: 3 as BoardSize,
    timeframe: Timeframe.DAILY,
    startDate: CREATED,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: CREATED,
    updatedAt: CREATED,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.COUNTING,
    maxCount: 10,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: CREATED,
    updatedAt: CREATED,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeEvent(id: string, taskId: string, over: Partial<TaskEvent> = {}): TaskEvent {
  return {
    id,
    userId: 'user-1',
    taskId,
    kind: 'increment',
    delta: 1,
    occurredAt: CREATED,
    createdAt: CREATED,
    updatedAt: CREATED,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeMember(over: Partial<SharedCounterMemberTask> = {}): SharedCounterMemberTask {
  return {
    taskId: 'member-1',
    taskTitle: 'Member 1',
    isSource: false,
    boardId: 'board-1',
    boardName: 'Board 1',
    timeframe: Timeframe.DAILY,
    window: null,
    goal: 100,
    logged: 40,
    met: false,
    over: 0,
    isActive: true,
    ...over,
  };
}

function makeGroup(over: Partial<SharedCounterGroup> = {}): SharedCounterGroup {
  return {
    counterId: 'source-1',
    name: 'Push-ups',
    action: 'Do',
    unit: 'push-ups',
    countKind: 'discrete',
    lifetime: 500,
    defaultLogAmount: 10,
    tasks: [makeMember({ taskId: 'source-1', isSource: true, boardId: null, boardName: null })],
    taskCount: 1,
    boardCount: 0,
    activeTaskCount: 0,
    ...over,
  };
}

// ─── buildBoardSettingsTileSummary ─────────────────────────────────────────

describe('buildBoardSettingsTileSummary', () => {
  it('formats the defaults line and a plural repeating-boards count', () => {
    const summary = buildBoardSettingsTileSummary(
      { defaultBoardSize: 3, defaultCenterType: CenterSquareType.FREE, weekStartDay: 'monday' },
      2,
    );
    expect(summary.defaultsLine).toBe('Defaults 3×3 · Free · Mon');
    expect(summary.repeatingLine).toBe('2 repeating boards');
  });

  it('formats None / Sun and a singular count', () => {
    const summary = buildBoardSettingsTileSummary(
      { defaultBoardSize: 5, defaultCenterType: CenterSquareType.NONE, weekStartDay: 'sunday' },
      1,
    );
    expect(summary.defaultsLine).toBe('Defaults 5×5 · None · Sun');
    expect(summary.repeatingLine).toBe('1 repeating board');
  });

  it('shows the empty-state copy verbatim at zero', () => {
    const summary = buildBoardSettingsTileSummary(
      { defaultBoardSize: 4, defaultCenterType: CenterSquareType.FREE, weekStartDay: 'monday' },
      0,
    );
    expect(summary.repeatingLine).toBe('No repeating boards yet');
  });
});

// ─── buildStreakTileData ────────────────────────────────────────────────────

describe('buildStreakTileData', () => {
  it('is empty when there is no bingo streak, even with completed boards elsewhere', () => {
    const now = new Date('2026-09-30T12:00:00.000');
    const boards = [
      // A completed (GREENLOGed) daily core board with NO bingo — doesn't
      // start a bingo streak, but still counts toward `greenlogCount`.
      makeBoard('b1', {
        isCore: true,
        timeframe: Timeframe.DAILY,
        startDate: '2026-09-29T00:00:00.000',
        status: BoardStatus.COMPLETED,
        linesCompleted: 0,
        completedAt: '2026-09-29T20:00:00.000',
      }),
    ];
    const data = buildStreakTileData(boards, 'monday', now);
    expect(data.currentBingoStreak).toBe(0);
    expect(data.isEmpty).toBe(true);
    expect(data.greenlogCount).toBe(1);
  });

  it('reports a non-empty bingo streak and the greenlog-based longest/count stats', () => {
    const now = new Date('2026-09-30T12:00:00.000');
    const boards = [
      makeBoard('today', {
        isCore: true,
        timeframe: Timeframe.DAILY,
        startDate: '2026-09-30T00:00:00.000',
        status: BoardStatus.ACTIVE,
        linesCompleted: 1, // bingo achieved today (current window)
      }),
      makeBoard('yesterday', {
        isCore: true,
        timeframe: Timeframe.DAILY,
        startDate: '2026-09-29T00:00:00.000',
        status: BoardStatus.COMPLETED,
        linesCompleted: 1,
        completedAt: '2026-09-29T20:00:00.000',
      }),
    ];
    const data = buildStreakTileData(boards, 'monday', now);
    expect(data.currentBingoStreak).toBe(2);
    expect(data.isEmpty).toBe(false);
    expect(data.longestGreenlogStreak).toBe(1); // only "yesterday" is COMPLETED
    expect(data.greenlogCount).toBe(1);
  });
});

// ─── formatLastLoggedLabel ──────────────────────────────────────────────────

describe('formatLastLoggedLabel', () => {
  const now = new Date('2026-09-30T18:00:00.000');

  it('labels the same calendar day as "today"', () => {
    expect(formatLastLoggedLabel('2026-09-30T09:00:00.000', now)).toBe('today');
  });

  it('labels the previous calendar day as "yesterday"', () => {
    expect(formatLastLoggedLabel('2026-09-29T23:50:00.000', now)).toBe('yesterday');
  });

  it('labels 2-6 days ago with a short weekday name', () => {
    // 2026-09-27 is a Sunday, 3 days before 2026-09-30.
    expect(formatLastLoggedLabel('2026-09-27T10:00:00.000', now)).toBe('Sun');
  });

  it('falls back to a short month/day date beyond a week', () => {
    expect(formatLastLoggedLabel('2026-09-10T10:00:00.000', now)).toBe('Sep 10');
  });

  it('returns an empty string for an unparseable timestamp', () => {
    expect(formatLastLoggedLabel('not-a-date', now)).toBe('');
  });
});

// ─── selectMostRecentlyLoggedMember ─────────────────────────────────────────

describe('selectMostRecentlyLoggedMember', () => {
  it('returns null when the counter has no linked members', () => {
    const group = makeGroup(); // source-only
    expect(selectMostRecentlyLoggedMember(group, new Map())).toBeNull();
  });

  it('picks the linked member whose raw task row was touched most recently', () => {
    const source = makeMember({ taskId: 'source-1', isSource: true, boardId: null, boardName: null });
    const older = makeMember({ taskId: 'm-old', boardName: 'February Fitness' });
    const newer = makeMember({ taskId: 'm-new', boardName: 'March Fitness' });
    const group = makeGroup({ tasks: [source, older, newer], taskCount: 3, boardCount: 2 });

    const tasksById = new Map<string, Task>([
      ['m-old', makeTask('m-old', { updatedAt: '2026-09-20T00:00:00.000Z' })],
      ['m-new', makeTask('m-new', { updatedAt: '2026-09-29T00:00:00.000Z' })],
    ]);

    const picked = selectMostRecentlyLoggedMember(group, tasksById);
    expect(picked?.taskId).toBe('m-new');
  });

  it('breaks a tie on board name deterministically', () => {
    const source = makeMember({ taskId: 'source-1', isSource: true, boardId: null, boardName: null });
    const a = makeMember({ taskId: 'm-a', boardName: 'Zebra Board' });
    const b = makeMember({ taskId: 'm-b', boardName: 'Alpha Board' });
    const group = makeGroup({ tasks: [source, a, b], taskCount: 3, boardCount: 2 });

    const sameStamp = '2026-09-20T00:00:00.000Z';
    const tasksById = new Map<string, Task>([
      ['m-a', makeTask('m-a', { updatedAt: sameStamp })],
      ['m-b', makeTask('m-b', { updatedAt: sameStamp })],
    ]);

    expect(selectMostRecentlyLoggedMember(group, tasksById)?.taskId).toBe('m-b');
  });
});

// ─── lastLoggedTimestamp / selectRecentCounters ─────────────────────────────

describe('lastLoggedTimestamp', () => {
  it('uses the most recent non-seed increment event createdAt', () => {
    const group = makeGroup({ counterId: 'source-1' });
    const events: Record<string, TaskEvent[]> = {
      'source-1': [
        makeEvent('e1', 'source-1', { createdAt: '2026-09-10T00:00:00.000Z' }),
        makeEvent('e2', 'source-1', { createdAt: '2026-09-20T00:00:00.000Z' }),
      ],
    };
    expect(lastLoggedTimestamp(group, new Map(), events)).toBe('2026-09-20T00:00:00.000Z');
  });

  it('falls back to the source task createdAt when never logged', () => {
    const group = makeGroup({ counterId: 'source-1' });
    const tasksById = new Map<string, Task>([['source-1', makeTask('source-1', { createdAt: '2026-05-01T00:00:00.000Z' })]]);
    expect(lastLoggedTimestamp(group, tasksById, {})).toBe('2026-05-01T00:00:00.000Z');
  });
});

describe('selectRecentCounters', () => {
  it('orders groups most-recently-logged first and caps at the limit', () => {
    const groupA = makeGroup({ counterId: 'a', name: 'Push-ups' });
    const groupB = makeGroup({ counterId: 'b', name: 'Pages read' });
    const groupC = makeGroup({ counterId: 'c', name: 'Miles run' });

    const events: Record<string, TaskEvent[]> = {
      a: [makeEvent('ea', 'a', { createdAt: '2026-09-10T00:00:00.000Z' })],
      b: [makeEvent('eb', 'b', { createdAt: '2026-09-29T00:00:00.000Z' })],
      c: [makeEvent('ec', 'c', { createdAt: '2026-09-20T00:00:00.000Z' })],
    };

    const result = selectRecentCounters([groupA, groupB, groupC], new Map(), events, 2);
    expect(result.map((r) => r.group.counterId)).toEqual(['b', 'c']);
  });

  it('breaks an equal-timestamp tie on counterId ascending (same rule as iOS)', () => {
    const groupZ = makeGroup({ counterId: 'z', name: 'Zed' });
    const groupA = makeGroup({ counterId: 'a', name: 'Alpha' });
    const same = '2026-09-29T00:00:00.000Z';
    const events: Record<string, TaskEvent[]> = {
      z: [makeEvent('ez', 'z', { createdAt: same })],
      a: [makeEvent('ea', 'a', { createdAt: same })],
    };

    // Input order is z-first; a deterministic tie-break must NOT depend on it.
    const result = selectRecentCounters([groupZ, groupA], new Map(), events, 2);
    expect(result.map((r) => r.group.counterId)).toEqual(['a', 'z']);
  });

  it('attaches the resolved member for each row', () => {
    const source = makeMember({ taskId: 'source-1', isSource: true, boardId: null, boardName: null });
    const linked = makeMember({ taskId: 'm-1', boardName: 'Spring 10K' });
    const group = makeGroup({ counterId: 'source-1', tasks: [source, linked], taskCount: 2, boardCount: 1 });
    const tasksById = new Map<string, Task>([['m-1', makeTask('m-1', { updatedAt: '2026-09-25T00:00:00.000Z' })]]);

    const result = selectRecentCounters([group], tasksById, {}, 2);
    expect(result[0].member?.taskId).toBe('m-1');
  });
});
