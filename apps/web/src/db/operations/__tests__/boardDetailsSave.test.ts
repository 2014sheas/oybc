import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  type Board,
} from '@oybc/shared';
import { db } from '../../internal';
import { BoardNotEditableError, saveBoardDetails } from '../boards';

/**
 * Board Edit redesign slice 2 (T1) — `saveBoardDetails`, the Board details
 * sheet's own atomic metadata save (plan D4), and the D11 editable guard it
 * runs first: a board sealed or deleted mid-session throws a typed
 * `BoardNotEditableError` with nothing written, instead of the silent no-op
 * that used to let the UI report "Board saved". iOS twin:
 * `BoardDetailsSaveTests`.
 */

const START = '2026-07-01T00:00:00.000';

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Original name',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.INDEFINITE,
    startDate: START,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('saveBoardDetails', () => {
  it('saves a rename + an ongoing board start date, bumps the version, and enqueues', async () => {
    await seedBoard();
    await saveBoardDetails('board-1', {
      name: 'Renamed',
      startDate: '2026-06-15T00:00:00.000',
    });

    const board = await db.boards.get('board-1');
    expect(board?.name).toBe('Renamed');
    expect(board?.startDate).toBe('2026-06-15T00:00:00.000');
    expect(board?.timeframe).toBe(Timeframe.INDEFINITE);
    expect(board?.version).toBe(2);
    const queued = await db.syncQueue
      .where('[entityType+entityId]')
      .equals(['boards', 'board-1'])
      .toArray();
    expect(queued.length).toBeGreaterThan(0);
  });

  it('a sealed board throws BoardNotEditableError — no write, no sync-queue row', async () => {
    await seedBoard({ sealedAt: '2026-07-02T00:00:00.000Z' });
    await expect(saveBoardDetails('board-1', { name: 'Renamed' })).rejects.toBeInstanceOf(
      BoardNotEditableError,
    );

    const board = await db.boards.get('board-1');
    expect(board?.name).toBe('Original name');
    expect(board?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('a deleted board throws BoardNotEditableError', async () => {
    await seedBoard({ isDeleted: true, deletedAt: START });
    await expect(saveBoardDetails('board-1', { name: 'Renamed' })).rejects.toBeInstanceOf(
      BoardNotEditableError,
    );
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('a missing board throws BoardNotEditableError', async () => {
    await expect(saveBoardDetails('nope', { name: 'Renamed' })).rejects.toBeInstanceOf(
      BoardNotEditableError,
    );
  });
});
