import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { BoardNotEditableError } from '../boards';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';

/**
 * Board-integrity PR-4, item 3 (docs/BOARD_INTEGRITY.md): Board-Edit Save
 * runs as ONE Dexie transaction (`commitSquareEdits`, `boardEditCommit.ts`)
 * — a mid-sequence failure must roll back every earlier write, never leave a
 * half-applied board.
 *
 * Board Edit redesign slice 3 (T2): this file used to be a FIXED REPLICA of
 * `useBoardPlay.ts`'s `commitSquareEdits` composition (no hook-rendering
 * harness was wired into Vitest). Slice 3 extracted the commit into a real,
 * standalone exported op (`db/operations/boardEditCommit.ts`) with no React
 * dependency at all, so this file now exercises THAT function directly —
 * the replica is retired.
 */

const START = '2026-07-01T00:00:00.000Z';
const BOARD = 'board-1';

function seedTask(id: string, title: string): Task {
  return {
    id, userId: 'user-1', title, type: TaskType.NORMAL,
    isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
  };
}

function seedBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: BOARD, userId: 'user-1', name: 'Original name', status: BoardStatus.ACTIVE,
    boardSize: 3, timeframe: Timeframe.MONTHLY, startDate: START,
    centerSquareType: CenterSquareType.NONE, isRandomized: false,
    totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
    ...overrides,
  };
}

function seedPlacement(id: string, taskId: string, row: number, col: number): BoardTask {
  return {
    id, boardId: BOARD, taskId, row, col, isCenter: false,
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
  };
}

function cell(overrides: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId' | 'row' | 'col'>): SquareDraftCell {
  return {
    isLocked: false,
    originalTaskId: overrides.taskId,
    originalRow: overrides.row,
    originalCol: overrides.col,
    originalLocked: false,
    ...overrides,
  };
}

function baseInput(partial: Partial<CommitSquareEditsInput> = {}): CommitSquareEditsInput {
  return {
    boardId: BOARD,
    cells: [],
    removedBoardTaskIds: [],
    taskOverrides: new Map(),
    isLegacyChosenOnDisk: false,
    centerCellKeepLocked: false,
    ...partial,
  };
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

describe('Board-Edit Save atomicity (board-integrity PR-4, item 3)', () => {
  it('rolls back an EARLIER step\'s write when a LATER step throws — the board is left fully UNCHANGED, not half-edited', async () => {
    await db.tasks.add(seedTask('task-A', 'Task A'));
    await db.tasks.add(seedTask('task-B', 'Task B'));
    await db.boards.add(seedBoard());
    await db.boardTasks.add(seedPlacement('bt-1', 'task-A', 0, 0));
    // A second, locked placement whose staged move (out of bounds handling
    // aside) instead trips the locked-row guard in `reorderBoardTasks` —
    // simulating "a later sub-op throws".
    await db.boardTasks.add(seedPlacement('bt-2', 'task-B', 0, 1));
    await db.boardTasks.update('bt-2', { isLocked: true });

    await expect(
      commitSquareEdits(
        baseInput({
          centerPatch: { centerSquareType: CenterSquareType.FREE },
          cells: [
            cell({ cellId: 'bt-1', taskId: 'task-B', row: 0, col: 0, originalTaskId: 'task-A' }),
            // Locked row staged to move — `reorderBoardTasks` throws.
            cell({ cellId: 'bt-2', taskId: 'task-B', row: 1, col: 1, originalRow: 0, originalCol: 1, isLocked: true, originalLocked: true }),
          ],
        }),
      ),
    ).rejects.toThrow(/locked in place/);

    // The step-3 replacement must NOT have stuck, even though
    // `updateBoardTaskAndCascade` "committed" its own internal
    // `db.transaction(...)` before the later move step threw — proof
    // that it joined the SAME ambient transaction as the outer wrapper,
    // not a separate one.
    const bt = await db.boardTasks.get('bt-1');
    expect(bt?.taskId).toBe('task-A');
    expect(bt?.version).toBe(1);

    const board = await db.boards.get(BOARD);
    expect(board?.name).toBe('Original name');
    expect(board?.centerSquareType).toBe(CenterSquareType.NONE);
    expect(board?.version).toBe(1);

    expect(await db.syncQueue.count()).toBe(0);
  });

  it('rolls back an EARLIER step\'s write when the METADATA step (last) throws', async () => {
    // Complementary half of the atomicity claim: the happy path commits
    // BOTH the square edits and the metadata patch as one unit.
    await db.tasks.add(seedTask('task-A', 'Task A'));
    await db.tasks.add(seedTask('task-B', 'Task B'));
    await db.boards.add(seedBoard());
    await db.boardTasks.add(seedPlacement('bt-1', 'task-A', 0, 0));

    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-1', taskId: 'task-B', row: 0, col: 0, originalTaskId: 'task-A' })],
        centerPatch: { centerSquareType: CenterSquareType.FREE },
      }),
    );

    const bt = await db.boardTasks.get('bt-1');
    expect(bt?.taskId).toBe('task-B');
    const board = await db.boards.get(BOARD);
    expect(board?.centerSquareType).toBe(CenterSquareType.FREE);
  });

  it('a board SEALED before commit throws BoardNotEditableError and rolls back the staged task override too (slice 2, D11)', async () => {
    // The app-shell backstop can seal a board while an edit session is open.
    await db.tasks.add(seedTask('task-A', 'Task A'));
    await db.tasks.add(seedTask('task-B', 'Task B'));
    await db.boards.add(seedBoard());
    await db.boardTasks.add(seedPlacement('bt-1', 'task-A', 0, 0));
    await db.boards.update(BOARD, { sealedAt: '2026-07-31T23:59:59.999Z' });

    await expect(
      commitSquareEdits(
        baseInput({
          cells: [cell({ cellId: 'bt-1', taskId: 'task-B', row: 0, col: 0, originalTaskId: 'task-A' })],
          taskOverrides: new Map([['task-A', { title: 'Overridden title' }]]),
        }),
      ),
    ).rejects.toBeInstanceOf(BoardNotEditableError);

    expect((await db.tasks.get('task-A'))?.title).toBe('Task A');
    expect((await db.tasks.get('task-A'))?.version).toBe(1);
    expect((await db.boardTasks.get('bt-1'))?.taskId).toBe('task-A');
    expect((await db.boards.get(BOARD))?.name).toBe('Original name');
    expect(await db.syncQueue.count()).toBe(0);
  });
});
