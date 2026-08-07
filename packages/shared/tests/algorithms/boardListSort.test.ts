import { compareBoardsForList } from '../../src/algorithms/boardListSort';
import type { Board } from '../../src/types/board';
import { BoardStatus, CenterSquareType, Timeframe } from '../../src/constants/enums';

const NOW = new Date('2026-06-15T12:00:00.000Z');

function makeBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'b',
    userId: 'u',
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe: Timeframe.CUSTOM,
    startDate: '2026-06-01T00:00:00.000Z',
    endDate: '2026-06-30T00:00:00.000Z',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-06-01T00:00:00.000Z',
    updatedAt: '2026-06-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/** Sort a list with the comparator against the fixed NOW. */
function sortIds(boards: Board[]): string[] {
  return [...boards].sort((a, b) => compareBoardsForList(a, b, NOW)).map((b) => b.id);
}

describe('compareBoardsForList', () => {
  it('orders active boards before non-active boards', () => {
    const active = makeBoard({ id: 'active', status: BoardStatus.ACTIVE });
    const completed = makeBoard({ id: 'completed', status: BoardStatus.COMPLETED });
    expect(sortIds([completed, active])).toEqual(['active', 'completed']);
  });

  it('within active: soonest endDate first', () => {
    const soon = makeBoard({ id: 'soon', endDate: '2026-06-20T00:00:00.000Z' });
    const later = makeBoard({ id: 'later', endDate: '2026-06-28T00:00:00.000Z' });
    expect(sortIds([later, soon])).toEqual(['soon', 'later']);
  });

  it('within active: no-deadline (INDEFINITE) boards sort last', () => {
    const dated = makeBoard({ id: 'dated', endDate: '2026-06-25T00:00:00.000Z' });
    const indefinite = makeBoard({
      id: 'indef',
      timeframe: Timeframe.INDEFINITE,
      endDate: undefined,
    });
    expect(sortIds([indefinite, dated])).toEqual(['dated', 'indef']);
  });

  it('within active: same endDate breaks ties by most recent activity', () => {
    const stale = makeBoard({
      id: 'stale',
      endDate: '2026-06-25T00:00:00.000Z',
      updatedAt: '2026-06-02T00:00:00.000Z',
    });
    const fresh = makeBoard({
      id: 'fresh',
      endDate: '2026-06-25T00:00:00.000Z',
      updatedAt: '2026-06-10T00:00:00.000Z',
    });
    expect(sortIds([stale, fresh])).toEqual(['fresh', 'stale']);
  });

  it('within non-active: most recent activity first', () => {
    const older = makeBoard({
      id: 'older',
      status: BoardStatus.COMPLETED,
      updatedAt: '2026-06-05T00:00:00.000Z',
    });
    const newer = makeBoard({
      id: 'newer',
      status: BoardStatus.COMPLETED,
      updatedAt: '2026-06-12T00:00:00.000Z',
    });
    expect(sortIds([older, newer])).toEqual(['newer', 'older']);
  });

  it('treats an ACTIVE-but-expired board as non-active (sorts with the recency group)', () => {
    const active = makeBoard({ id: 'active', endDate: '2026-06-25T00:00:00.000Z' });
    const expired = makeBoard({
      id: 'expired',
      status: BoardStatus.ACTIVE,
      endDate: '2026-06-01T00:00:00.000Z', // before NOW
    });
    expect(sortIds([expired, active])).toEqual(['active', 'expired']);
  });

  it('treats a sealed ACTIVE board as non-active', () => {
    const active = makeBoard({ id: 'active', endDate: '2026-06-25T00:00:00.000Z' });
    const sealed = makeBoard({
      id: 'sealed',
      status: BoardStatus.ACTIVE,
      endDate: '2026-06-20T00:00:00.000Z',
      sealedAt: '2026-06-10T00:00:00.000Z',
    });
    expect(sortIds([sealed, active])).toEqual(['active', 'sealed']);
  });

  it('mixed list (All tab): active-by-deadline, then non-active-by-recency', () => {
    const activeSoon = makeBoard({ id: 'activeSoon', endDate: '2026-06-18T00:00:00.000Z' });
    const activeLate = makeBoard({ id: 'activeLate', endDate: '2026-06-29T00:00:00.000Z' });
    const activeIndef = makeBoard({
      id: 'activeIndef',
      timeframe: Timeframe.INDEFINITE,
      endDate: undefined,
    });
    const doneOld = makeBoard({
      id: 'doneOld',
      status: BoardStatus.COMPLETED,
      updatedAt: '2026-06-03T00:00:00.000Z',
    });
    const doneNew = makeBoard({
      id: 'doneNew',
      status: BoardStatus.COMPLETED,
      updatedAt: '2026-06-14T00:00:00.000Z',
    });
    expect(sortIds([doneOld, activeLate, doneNew, activeIndef, activeSoon])).toEqual([
      'activeSoon',
      'activeLate',
      'activeIndef',
      'doneNew',
      'doneOld',
    ]);
  });

  it('sorts DRAFT boards with the non-active recency group', () => {
    const active = makeBoard({ id: 'active', endDate: '2026-06-25T00:00:00.000Z' });
    const draftOld = makeBoard({
      id: 'draftOld',
      status: BoardStatus.DRAFT,
      updatedAt: '2026-06-04T00:00:00.000Z',
    });
    const draftNew = makeBoard({
      id: 'draftNew',
      status: BoardStatus.DRAFT,
      updatedAt: '2026-06-11T00:00:00.000Z',
    });
    expect(sortIds([draftOld, active, draftNew])).toEqual(['active', 'draftNew', 'draftOld']);
  });
});
