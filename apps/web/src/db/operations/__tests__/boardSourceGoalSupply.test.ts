import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  derivedTaskId,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { resolveBoardSourceSupply } from '../boardSources';
import { persistWizardBoardRows, type PersistWizardBoardRowsInput } from '../wizardBoard';

/**
 * TASK_WINDOW_REWORK slice 3a — a board source supplies each member's
 * EFFECTIVE goal (the placement's `targetOverride`; a compound placement's
 * `childTargets`), and the pull pro-rates from it, never from the root's own
 * goal. Reference vector (shared `memberRuleVectors`): r1 own 35, placed at
 * 70 weekly, pulled to daily gives 10.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const SOURCE_BOARD = '70000000-0000-4000-8000-000000000001';
const ROOT = '70000000-0000-4000-8000-000000000002';
const COMP = '70000000-0000-4000-8000-000000000003';
const KID = '70000000-0000-4000-8000-000000000004';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: START, updatedAt: START, version: 1, isDeleted: false, ...over,
  };
}

function counter(id: string, maxCount: number): Task {
  return task(id, { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount, title: `Run ${maxCount} km` });
}

function board(over: Partial<Board> = {}): Board {
  return {
    id: SOURCE_BOARD, userId: USER, name: 'Source', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
    startDate: '2026-06-22T00:00:00.000', endDate: '2026-06-28T23:59:59.999', centerSquareType: CenterSquareType.NONE,
    isRandomized: false, totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
    createdAt: START, updatedAt: START, version: 1, isDeleted: false, ...over,
  } as Board;
}

function placement(id: string, taskId: string, over: Partial<BoardTask> = {}): BoardTask {
  return { id, boardId: SOURCE_BOARD, taskId, row: 0, col: 0, isCenter: false, createdAt: START, updatedAt: START, version: 1, isDeleted: false, ...over };
}

describe('resolveBoardSourceSupply — goalByTaskId', () => {
  it('carries a counting placement\'s targetOverride, keyed by the supplied task', () => {
    const info = resolveBoardSourceSupply(
      board(),
      [
        placement('p1', ROOT, { targetOverride: 70, targetKind: 'discrete' }),
        placement('p2', 'plain', { col: 1 }),
      ],
      { [ROOT]: counter(ROOT, 35), plain: counter('plain', 10) },
      {},
    );
    expect(info.goalByTaskId).toEqual({ [ROOT]: 70 });
  });

  it('carries a compound placement\'s childTargets keyed by child id', () => {
    const info = resolveBoardSourceSupply(
      board(),
      [placement('p1', COMP, { childTargets: [{ childId: KID, target: 12 }] })],
      { [COMP]: task(COMP, { type: TaskType.COMPOUND }), [KID]: counter(KID, 40) },
      {},
    );
    expect(info.goalByTaskId).toEqual({ [KID]: 12 });
  });

  it('is empty for a placement with no parameters, and ignores a deleted row', () => {
    const info = resolveBoardSourceSupply(
      board(),
      [placement('p1', ROOT), placement('p2', 'gone', { targetOverride: 9, isDeleted: true })],
      { [ROOT]: counter(ROOT, 35), gone: counter('gone', 5) },
      {},
    );
    expect(info.goalByTaskId).toEqual({});
  });
});

describe('persistWizardBoardRows — pulling from a board that holds an overridden root placement', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-06-25T12:00:00.000'));
  });
  afterEach(async () => {
    vi.useRealTimers();
    await Promise.all(
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.pools, db.syncQueue].map((t) => t.clear()),
    );
  });

  async function pullFrom(sourcePlacement: Partial<BoardTask>): Promise<Task | undefined> {
    const root = counter(ROOT, 35);
    await db.tasks.add(root);
    await db.boards.add(board());
    await db.boardTasks.add(placement('bt-src', ROOT, sourcePlacement));
    const input: PersistWizardBoardRowsInput = {
      userId: USER,
      draftBoardId: null,
      isCore: false,
      isRecurringDraft: false,
      status: 'active',
      boardFields: {
        name: 'Daily', boardSize: 3, timeframe: Timeframe.DAILY, startDate: START,
        centerSquareType: CenterSquareType.NONE, isRandomized: false,
      },
      placement: [root, ...new Array(8).fill(null)],
      size: 3,
      centerType: CenterSquareType.NONE,
      pendingTasks: [],
      sources: [{ sourceId: SOURCE_BOARD, kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all' }],
      manualTaskIds: [],
    };
    const boardId = await persistWizardBoardRows(input);
    return db.tasks.get(derivedTaskId(boardId, ROOT));
  }

  it('pro-rates from the SUPPLYING placement\'s goal: 70 weekly gives 10 daily (not 35 -> 5)', async () => {
    const minted = await pullFrom({ targetOverride: 70, targetKind: 'discrete' });
    expect(minted?.maxCount).toBe(10);
  });

  it('control: with no override the root\'s own goal pro-rates (35 weekly gives 5 daily)', async () => {
    const minted = await pullFrom({});
    expect(minted?.maxCount).toBe(5);
  });
});
