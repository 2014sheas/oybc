import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  TaskType,
  findTemplatesPendingSpawn,
  getTimeframeBoundaries,
  validateSpawnPool,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { repeatBoardAsRecurring } from '../repeatBoard';
import { deleteBoard } from '../boards';

/**
 * P6 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 7) — "Repeat this board…" write. Integration coverage for
 * `repeatBoardAsRecurring`: the multi-table transaction (template insert +
 * board back-stamp), not just `buildRepeatBoardTemplateInput` in isolation
 * (already unit-tested in `packages/shared/tests/algorithms/
 * recurringBoardTemplates.test.ts`).
 */

const USER_ID = 'user-1';
const NOW = '2026-05-07T00:00:00.000Z';

async function seedTask(id: string): Promise<Task> {
  const task: Task = {
    id,
    userId: USER_ID,
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  return task;
}

function buildOneOffBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: USER_ID,
    name: 'Morning Routine',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-05-06T00:00:00.000', // Wednesday, in the Mon May 4 – Sun May 10 week
    endDate: '2026-05-06T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 9,
    completedTasks: 1, // auto-completed FREE center
    linesCompleted: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

async function seedBoardTask(
  boardId: string,
  taskId: string,
  row: number,
  col: number,
  overrides: Partial<BoardTask> = {},
): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${row}-${col}`,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boardTasks.add(bt);
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.recurringBoardTemplates.clear();
  await db.syncQueue.clear();
});

describe('repeatBoardAsRecurring', () => {
  it('mints a template whose manualTaskIds match the board\'s live placed tasks, and back-stamps the board', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    const taskIds = ['t0', 't1', 't2', 't3', 't4', 't5', 't6', 't7'];
    for (const id of taskIds) await seedTask(id);
    // 3x3 FREE center — 8 fillable cells, skip the center (row1,col1).
    let i = 0;
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 3; col++) {
        if (row === 1 && col === 1) continue;
        await seedBoardTask(board.id, taskIds[i], row, col);
        i++;
      }
    }

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(new Set(template.manualTaskIds)).toEqual(new Set(taskIds));
    expect(template.poolIds).toEqual([]);
    expect(template.removedTaskIds).toEqual([]);
    expect(template.isActive).toBe(true);
    expect(template.userId).toBe(USER_ID);
    expect(template.centerSquareType).toBe(CenterSquareType.FREE);
    expect(template.boardSize).toBe(3);

    const updatedBoard = await db.boards.get(board.id);
    expect(updatedBoard?.spawnedFromTemplateId).toBe(template.id);
    expect(updatedBoard?.version).toBe((board.version ?? 0) + 1);

    // Both writes queued for sync.
    const queued = await db.syncQueue.toArray();
    const entityTypes = queued.map((q) => q.entityType);
    expect(entityTypes).toContain('recurringBoardTemplates');
    expect(entityTypes).toContain('boards');
  });

  it("back-stamps the version from the LIVE board row, not the caller's stale snapshot (Board Edit two-phase Save)", async () => {
    // Board Edit's Save commits a board write (version bump) and THEN calls
    // repeatBoardAsRecurring with a snapshot that may predate it. The
    // back-stamp must advance the LIVE version or the write loses the LWW
    // tie-break on sync.
    const board = buildOneOffBoard({ version: 1 });
    await db.boards.add(board);
    await seedTask('t0');
    await seedBoardTask(board.id, 't0', 0, 0);

    // Simulate the phase-1 board save bumping the stored row past the snapshot.
    await db.boards.update(board.id, { version: 5 });

    await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    const updatedBoard = await db.boards.get(board.id);
    expect(updatedBoard?.version).toBe(6); // live 5 + 1, not snapshot 1 + 1
  });

  it('lastSpawnedWindowKey is keyed off the CHOSEN cadence, not board.timeframe (critical window-alignment vector)', async () => {
    // DAILY board dated a Wednesday (2026-05-06), repeated WEEKLY (Monday
    // week start) — the window key must be the week's Monday (May 4), NOT
    // the Wednesday the board itself is dated for.
    const board = buildOneOffBoard({ timeframe: Timeframe.DAILY, startDate: '2026-05-06T00:00:00.000' });
    await db.boards.add(board);
    await seedTask('only-task');
    await seedBoardTask(board.id, 'only-task', 0, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.WEEKLY, USER_ID, 'monday');

    const expectedWeekWindow = getTimeframeBoundaries(
      Timeframe.WEEKLY,
      new Date('2026-05-06T00:00:00.000'),
      'monday',
    );
    expect(expectedWeekWindow.startDate).not.toBe(board.startDate);
    expect(template.lastSpawnedWindowKey).toBe(expectedWeekWindow.startDate);
    expect(template.timeframe).toBe(Timeframe.WEEKLY);
  });

  it('findTemplatesPendingSpawn does not flag the new template as pending for the window it was just written against (no immediate duplicate spawn)', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('solo-task');
    await seedBoardTask(board.id, 'solo-task', 0, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    // "Now" = the same reference date the board's startDate represents —
    // the window `findTemplatesPendingSpawn` would check on the very next
    // Boards-tab open.
    const referenceNow = new Date('2026-05-06T09:00:00.000');
    const allBoards = await db.boards.toArray();
    const pending = findTemplatesPendingSpawn([template], allBoards, 'monday', referenceNow);
    expect(pending).toHaveLength(0);
  });

  it('does not touch isCore, status, or other board fields', async () => {
    const board = buildOneOffBoard({ isCore: false, status: BoardStatus.ACTIVE, name: 'Keep My Name' });
    await db.boards.add(board);
    await seedTask('x');
    await seedBoardTask(board.id, 'x', 0, 0);

    await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    const updatedBoard = await db.boards.get(board.id);
    expect(updatedBoard?.isCore).toBe(false);
    expect(updatedBoard?.status).toBe(BoardStatus.ACTIVE);
    expect(updatedBoard?.name).toBe('Keep My Name');
  });

  it('dedupes a task placed on multiple cells (defensive) and preserves grid order', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('dup-task');
    await seedTask('other-task');
    await seedBoardTask(board.id, 'dup-task', 0, 0);
    await seedBoardTask(board.id, 'other-task', 0, 1);
    // Same task placed again elsewhere (shouldn't normally happen, but the
    // dedup must hold regardless).
    await seedBoardTask(board.id, 'dup-task', 0, 2, { id: 'bt-dup-2' });

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(template.manualTaskIds).toEqual(['dup-task', 'other-task']);
  });
  it('writes an explicit sources-native record: sources [], manualTaskVary {} (B2 RB4)', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('t-a');
    await seedBoardTask(board.id, 't-a', 0, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    // The record is authored in today's shape, not left to `sourcesForRecord`
    // inference: a repeat-this-board record pulls from no source at all.
    expect(template.sources).toEqual([]);
    expect(template.manualTaskVary).toEqual({});
    const stored = await db.recurringBoardTemplates.get(template.id);
    expect(stored?.sources).toEqual([]);
    expect(stored?.manualTaskVary).toEqual({});
  });

  it('drops a per-window derived COMPOUND and records a derived COUNTER by its root (B2 RB4, amended)', async () => {
    // A derived compound is an artifact of ONE window — carrying it forward
    // as a hand-added member would pin every future window to last window's
    // re-targeted copy. A derived COUNTER is dropped in favour of its ROOT:
    // the derived row dies with this board (RB5), so recording it would kill
    // the repeating record the day the user deletes the board they repeated.
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('plain-1');
    await seedTask('root-1');
    await db.tasks.add({
      id: 'derived-compound-1',
      userId: USER_ID,
      title: 'Circuit (this week)',
      type: TaskType.COMPOUND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: '2026-05-06T00:00:00.000',
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await db.tasks.add({
      id: 'derived-counter-1',
      userId: USER_ID,
      title: 'Run 5 km (this week)',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 5,
      sharedCounterId: 'root-1',
      baseline: 0,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: '2026-05-06T00:00:00.000',
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    // A hand-made COMPOUND with no window stamp stays a member.
    await db.tasks.add({
      id: 'plain-compound-1',
      userId: USER_ID,
      title: 'Morning circuit',
      type: TaskType.COMPOUND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await seedBoardTask(board.id, 'plain-1', 0, 0);
    await seedBoardTask(board.id, 'derived-compound-1', 0, 1);
    await seedBoardTask(board.id, 'derived-counter-1', 0, 2);
    await seedBoardTask(board.id, 'plain-compound-1', 1, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(template.manualTaskIds).toEqual(['plain-1', 'root-1', 'plain-compound-1']);
    expect(template.manualTaskIds).not.toContain('derived-counter-1');
    expect(template.seedTaskIds).not.toContain('derived-compound-1');
  });

  it('survives deleting the board it was repeated from — no has_deleted_tasks (FI2)', async () => {
    // The regression FI2 names: before the amendment the record's manual
    // layer held the DERIVED id, the board delete retired that row, and
    // `validateSpawnPool` then skipped every future window.
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('root-2');
    await db.tasks.add({
      id: 'derived-counter-2',
      userId: USER_ID,
      title: 'Run 5 km (this week)',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 5,
      sharedCounterId: 'root-2',
      baseline: 0,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: '2026-05-06T00:00:00.000',
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await seedBoardTask(board.id, 'derived-counter-2', 0, 0);
    // A FREE-centre 3×3 wants 8 members; fill the rest so the only thing
    // `validateSpawnPool` can complain about is a dead member id.
    for (let i = 0; i < 7; i++) {
      await seedTask(`filler-${i}`);
      await seedBoardTask(board.id, `filler-${i}`, Math.floor((i + 1) / 3), (i + 1) % 3);
    }

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');
    expect(template.manualTaskIds).toContain('root-2');
    expect(template.manualTaskIds).not.toContain('derived-counter-2');

    await deleteBoard(board.id);

    const stored = await db.recurringBoardTemplates.get(template.id);
    const poolTasks = (
      await Promise.all((stored?.manualTaskIds ?? []).map((id) => db.tasks.get(id)))
    ).filter((t): t is Task => t != null);
    expect(poolTasks).toHaveLength(8);
    expect(poolTasks.some((t) => t.isDeleted)).toBe(false);
    expect(validateSpawnPool(stored!, poolTasks)).toEqual({ ok: true });
  });

  it('skips a derived counter whose root is gone rather than recording a dead id (FI2)', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('plain-2');
    const deadRoot = await seedTask('root-3');
    await db.tasks.put({ ...deadRoot, isDeleted: true, deletedAt: NOW });
    await db.tasks.add({
      id: 'derived-counter-3',
      userId: USER_ID,
      title: 'Walk 1 km (this week)',
      type: TaskType.COUNTING,
      action: 'Walk',
      unit: 'km',
      maxCount: 1,
      sharedCounterId: 'root-3',
      baseline: 0,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: '2026-05-06T00:00:00.000',
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await seedBoardTask(board.id, 'plain-2', 0, 0);
    await seedBoardTask(board.id, 'derived-counter-3', 0, 1);

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(template.manualTaskIds).toEqual(['plain-2']);
  });
});
