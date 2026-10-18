import { describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type BoardTask, type CompoundChild, type Task } from '@oybc/shared';
import { buildSquareWindowContext } from '../../../../db/adapters';
import type { PendingCounts } from '../../../../hooks/pendingCounts';
import { resolveSquareView, type SquareViewData } from '../resolveSquareView';

const NOW = '2026-01-01T00:00:00.000Z';
const board: Board = {
  id: 'b1', userId: 'u', name: 'B', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
  startDate: NOW, endDate: '2099-01-01T00:00:00.000Z', centerSquareType: CenterSquareType.NONE,
  isRandomized: false, totalTasks: 1, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: NOW, updatedAt: NOW,
  version: 1, isDeleted: false,
};
const task = (o: Partial<Task>): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...o,
}) as Task;
const bt = (taskId: string): BoardTask => ({ id: `bt-${taskId}`, boardId: 'b1', taskId, row: 0, col: 0, isCenter: false, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false });
const inc = (taskId: string, delta: number) => ({
  id: `${taskId}-${delta}`, userId: 'u', taskId, kind: 'increment', delta, occurredAt: '2026-01-02T00:00:00.000Z',
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
});

const READ = task({ id: 'read', type: TaskType.COUNTING, title: 'Read', action: 'Read', unit: 'pages', maxCount: 20, currentCount: 0 });
const KID = task({ id: 'kid', type: TaskType.COUNTING, title: 'Kid', action: 'Do', unit: 'x', maxCount: 5, currentCount: 0 });
const COMPOUND = task({ id: 'cmp', type: TaskType.COMPOUND, title: 'Both', operator: 'AND' } as Partial<Task>);
const LINK: CompoundChild = { id: 'cc', compoundTaskId: 'cmp', childTaskId: 'kid', childIndex: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false };

const data = (events: ReturnType<typeof inc>[]): SquareViewData => ({
  boardTasks: [bt('read'), bt('cmp')], taskMap: { read: READ, kid: KID, cmp: COMPOUND },
  compoundChildrenByCompound: { cmp: [LINK] }, allBoards: [], achievementBadgesByBoardTaskId: {}, cellStateByBoardTaskId: {},
  sharedCounterSourceIds: new Set(), gridSize: 3,
  squareWindowContext: buildSquareWindowContext(events as never, board.startDate, board.endDate ?? null),
});

describe('resolveSquareView with pending counts', () => {
  it('the sheet count moves to the expected value before the live data lands', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 17, settled: false }] };
    const view = resolveSquareView(board, data([inc('read', 12)]), bt('read'), READ, pending);
    expect(view.count).toBe(17);
  });

  it('shows the live count once it has reached the expectation (no double count)', () => {
    const pending: PendingCounts = { read: [{ id: 1, expected: 17, settled: true, settledAt: 'T' }] };
    expect(resolveSquareView(board, data([inc('read', 17)]), bt('read'), READ, pending).count).toBe(17);
  });

  it('is the live count with nothing pending', () => {
    expect(resolveSquareView(board, data([inc('read', 12)]), bt('read'), READ).count).toBe(12);
  });

  it("a compound's counting child row shows its pending count", () => {
    const pending: PendingCounts = { kid: [{ id: 1, expected: 4, settled: false }] };
    const view = resolveSquareView(board, data([inc('kid', 1)]), bt('cmp'), COMPOUND, pending);
    expect(view.sq.children?.[0].count?.current).toBe(4);
  });
});
