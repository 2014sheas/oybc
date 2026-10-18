import { describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type BoardTask, type Task } from '@oybc/shared';
import { buildSquareWindowContext } from '../../../db/adapters';
import type { PendingCounts } from '../../../hooks/pendingCounts';
import { buildPlayCellEntries, samePlayTaskEntry, type PlayCellEntry, type PlayCellInputs, type PlayTaskEntry } from '../boardPlayCells';

const NOW = '2026-01-01T00:00:00.000Z';

const board = (o: Partial<Board> = {}): Board => ({
  id: 'b1', userId: 'u', name: 'B', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
  startDate: NOW, endDate: '2099-01-01T00:00:00.000Z', centerSquareType: CenterSquareType.FREE,
  isRandomized: false, totalTasks: 2, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: NOW, updatedAt: NOW,
  version: 1, isDeleted: false, ...o,
});
const task = (o: Partial<Task>): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...o,
}) as Task;
const place = (id: string, taskId: string, row: number, col: number): BoardTask => ({
  id, boardId: 'b1', taskId, row, col, isCenter: false, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
});

const READ = task({ id: 'read', title: 'Read', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 20, currentCount: 0 });
const WALK = task({ id: 'walk', title: 'Walk' });
const btRead = place('bt-read', 'read', 0, 0);
const btWalk = place('bt-walk', 'walk', 0, 1);

function inputs(o: Partial<PlayCellInputs> = {}, events: Array<{ taskId: string; amount: number }> = []): PlayCellInputs {
  const b = board();
  const evts = events.map((e, i) => ({
    id: `e${i}`, userId: 'u', taskId: e.taskId, kind: 'increment', delta: e.amount, occurredAt: '2026-01-02T00:00:00.000Z',
    createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
  }));
  return {
    board: b, gridSize: 3, btByPosition: { '0-0': btRead, '0-1': btWalk },
    taskMap: { read: READ, walk: WALK }, compoundChildrenByCompound: {}, cellStateByBoardTaskId: {},
    squareWindowContext: buildSquareWindowContext(evts as never, b.startDate, b.endDate ?? null),
    sharedCounterSourceIds: new Set(), achievementBoardTaskIds: new Set(), liveCompletedLineIds: [], arrivedTaskIds: new Set(),
    pendingCounts: {}, ...o,
  };
}

const taskEntry = (entries: PlayCellEntry[], id: string): PlayTaskEntry => {
  const e = entries.find((x) => x.kind === 'task' && x.boardTaskId === id);
  if (!e || e.kind !== 'task') throw new Error(`no task entry ${id}`);
  return e;
};

describe('buildPlayCellEntries', () => {
  it('resolves 9 positions: tasks, the FREE center and empties', () => {
    const entries = buildPlayCellEntries(inputs());
    expect(entries).toHaveLength(9);
    expect(entries.filter((e) => e.kind === 'task')).toHaveLength(2);
    expect(entries.find((e) => e.kind === 'free')?.key).toBe('center-1-1');
    expect(entries.filter((e) => e.kind === 'empty')).toHaveLength(6);
  });

  it('a Normal square on an open board toggles on tap; a counting square opens the sheet', () => {
    const entries = buildPlayCellEntries(inputs());
    expect(taskEntry(entries, 'bt-walk').normalTap).toEqual({ taskId: 'walk', title: 'Walk', wasDone: false });
    expect(taskEntry(entries, 'bt-read').normalTap).toBeNull();
  });

  it('every square on a closed board opens the sheet', () => {
    const entries = buildPlayCellEntries(inputs({ board: board({ sealedAt: '2026-01-05T00:00:00.000Z' }) }));
    expect(taskEntry(entries, 'bt-walk').normalTap).toBeNull();
  });

  it('draws the windowed count from the events', () => {
    const entries = buildPlayCellEntries(inputs({}, [{ taskId: 'read', amount: 12 }]));
    expect(taskEntry(entries, 'bt-read').cell.count?.cur).toBe(12);
  });

  it('a pending log shows its expected count before the live data lands, and goes green at the goal', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 20, settled: false }] };
    const entries = buildPlayCellEntries(inputs({ pendingCounts: pending }, [{ taskId: 'read', amount: 12 }]));
    const cell = taskEntry(entries, 'bt-read').cell;
    expect(cell.count?.cur).toBe(20);
    expect(cell.done).toBe(true);
  });

  it('the same pending op over live data that already includes the write shows the live count (no double count)', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 17, settled: true, settledAt: 'T' }] };
    const entries = buildPlayCellEntries(inputs({ pendingCounts: pending }, [{ taskId: 'read', amount: 17 }]));
    expect(taskEntry(entries, 'bt-read').cell.count?.cur).toBe(17);
  });

  it('a pending removal moves the count down at once and takes the green back', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 15, settled: false }] };
    const entries = buildPlayCellEntries(inputs({ pendingCounts: pending }, [{ taskId: 'read', amount: 20 }]));
    const cell = taskEntry(entries, 'bt-read').cell;
    expect(cell.count?.cur).toBe(15);
    expect(cell.done).toBe(false);
  });

  it('ignores pending counts on a closed board', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 20, settled: false }] };
    const entries = buildPlayCellEntries(inputs({ board: board({ sealedAt: '2026-01-05T00:00:00.000Z' }), pendingCounts: pending }));
    expect(taskEntry(entries, 'bt-read').cell.count?.cur).toBe(0);
  });
});

describe('samePlayTaskEntry (the cell memo test)', () => {
  it('rebuilding unchanged inputs gives entries that need no re-render', () => {
    const a = taskEntry(buildPlayCellEntries(inputs()), 'bt-read');
    const b = taskEntry(buildPlayCellEntries(inputs()), 'bt-read');
    expect(a).not.toBe(b);
    expect(samePlayTaskEntry(a, b)).toBe(true);
  });

  it('a changed count re-renders only the square it belongs to', () => {
    const before = buildPlayCellEntries(inputs());
    const after = buildPlayCellEntries(inputs({}, [{ taskId: 'read', amount: 5 }]));
    expect(samePlayTaskEntry(taskEntry(before, 'bt-read'), taskEntry(after, 'bt-read'))).toBe(false);
    expect(samePlayTaskEntry(taskEntry(before, 'bt-walk'), taskEntry(after, 'bt-walk'))).toBe(true);
  });
});
