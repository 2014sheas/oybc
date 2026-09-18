import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { deleteTaskWithCascade } from '../tasks.deletion';
import { deleteCounterWithUnlink } from '../tasks.counter';

/**
 * Item 3 (bingo-pipeline hardening) — task delete / counter unlink ran no
 * board cascade. `deleteTaskWithCascadeInTxn` tombstoned placements
 * (soft-deleted, Board-integrity PR-1) + soft-deleted the Task but never
 * re-derived affected boards, so a
 * persisted bingo line could keep glowing through a now-empty cell until the
 * next app-open self-heal (achievements watching the board would read the
 * stale line meanwhile). The fix computes the affected-board set BEFORE the
 * delete (mirroring `removeBoardTaskFromBoard`'s reachability), then runs
 * the standard windowed cascade over those boards in the SAME transaction
 * as the delete writes.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';

function uuid(n: number): string {
  return `60000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedWindowedCompleteTask(id: string, title = 'T'): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `${id}-ev`,
    userId: USER,
    taskId: id,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
}

async function seedBoardWithCompletedRow0(
  boardId: string,
  taskIds: [string, string, string],
  over: Partial<Board> = {},
): Promise<void> {
  const board: Board = {
    id: boardId,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 3,
    linesCompleted: 1,
    completedLineIds: ['row_0'],
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.add(board);
  for (let col = 0; col < 3; col += 1) {
    const bt: BoardTask = {
      id: `bt-${boardId}-${col}`,
      boardId,
      taskId: taskIds[col],
      row: 0,
      col,
      isCenter: false,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.boardTasks.add(bt);
  }
}

async function boardSyncEntries(boardId: string) {
  return (await db.syncQueue.toArray()).filter(
    (i) => i.entityType === 'boards' && i.entityId === boardId,
  );
}

describe('deleteTaskWithCascade — board cascade (item 3)', () => {
  it('a persisted bingo line through the deleted task clears in the SAME call (no self-heal needed)', async () => {
    const [A, B, C] = [uuid(1), uuid(2), uuid(3)];
    const BOARD = uuid(10);
    await seedWindowedCompleteTask(A);
    await seedWindowedCompleteTask(B);
    await seedWindowedCompleteTask(C);
    await seedBoardWithCompletedRow0(BOARD, [A, B, C]);

    await deleteTaskWithCascade(A);

    const board = await db.boards.get(BOARD);
    expect(board?.completedLineIds).not.toContain('row_0');
    // Only B and C's cells remain complete — A's placement was tombstoned.
    expect(board?.completedTasks).toBe(2);
    expect(board?.version).toBe(2); // authored cascade write → version bump.

    const entries = await boardSyncEntries(BOARD);
    expect(entries.length).toBeGreaterThan(0);

    // The task itself is soft-deleted and its placement is TOMBSTONED
    // (Board-integrity PR-1, docs/BOARD_INTEGRITY.md): the row survives as
    // a soft delete, not a physical delete — a hard delete here would let
    // the pushed tombstone lose the LWW tie-break and resurrect the row.
    const task = await db.tasks.get(A);
    expect(task?.isDeleted).toBe(true);
    const placements = await db.boardTasks.where('taskId').equals(A).toArray();
    expect(placements).toHaveLength(1);
    expect(placements[0].isDeleted).toBe(true);
    expect(placements[0].deletedAt).toBeTruthy();
  });

  it('skips a sealed board — the frozen snapshot is not touched by the live cascade', async () => {
    const [A, B, C] = [uuid(4), uuid(5), uuid(6)];
    const BOARD = uuid(11);
    await seedWindowedCompleteTask(A);
    await seedWindowedCompleteTask(B);
    await seedWindowedCompleteTask(C);
    await seedBoardWithCompletedRow0(BOARD, [A, B, C], {
      sealedAt: '2026-07-02T06:00:00.000Z',
      sealedCompletedCells: [0, 1, 2],
      version: 5,
    });

    await deleteTaskWithCascade(A);

    const board = await db.boards.get(BOARD);
    // Sealed snapshot fields are frozen — untouched by this cascade.
    expect(board?.completedLineIds).toEqual(['row_0']);
    expect(board?.sealedCompletedCells).toEqual([0, 1, 2]);
    expect(board?.version).toBe(5); // not bumped — the board was skipped.

    // The task itself is still deleted regardless of the board skip.
    const task = await db.tasks.get(A);
    expect(task?.isDeleted).toBe(true);
  });

  it('is a no-op cascade when the task is placed on no board', async () => {
    const A = uuid(7);
    await seedWindowedCompleteTask(A);

    await expect(deleteTaskWithCascade(A)).resolves.not.toThrow();
    const task = await db.tasks.get(A);
    expect(task?.isDeleted).toBe(true);
  });
});

describe('deleteCounterWithUnlink — board cascade on the source’s own placements (item 3)', () => {
  it('clears a bingo line through the deleted SOURCE task in the same call; a member’s own placement (elsewhere) is untouched since unlink keeps it', async () => {
    // Source counter, placed directly on a board's bingo row alongside two
    // other complete tasks.
    const SOURCE = uuid(20);
    const OTHER_B = uuid(21);
    const OTHER_C = uuid(22);
    const BOARD = uuid(30);

    const source: Task = {
      id: SOURCE,
      userId: USER,
      title: 'Counter source',
      type: TaskType.COUNTING,
      action: 'Do',
      unit: 'reps',
      isCounter: true,
      maxCount: 10,
      currentCount: 10,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(source);
    // Source is event-owning (sharedCounterId == null) — needs an in-window
    // increment event reaching maxCount to resolve windowed-complete.
    await db.taskEvents.add({
      id: `${SOURCE}-ev`,
      userId: USER,
      taskId: SOURCE,
      kind: 'increment',
      delta: 10,
      occurredAt: IN_WINDOW,
      createdAt: IN_WINDOW,
      updatedAt: IN_WINDOW,
      version: 1,
      isDeleted: false,
    } as TaskEvent);
    await seedWindowedCompleteTask(OTHER_B);
    await seedWindowedCompleteTask(OTHER_C);
    await seedBoardWithCompletedRow0(BOARD, [SOURCE, OTHER_B, OTHER_C]);

    // A derived member elsewhere in the library, linked to this source, NOT
    // placed on any board — proves the member itself is unlinked (not
    // deleted) and the board cascade only concerns the source's own
    // placements.
    const member: Task = {
      id: uuid(23),
      userId: USER,
      title: 'Member',
      type: TaskType.COUNTING,
      action: 'Do',
      unit: 'reps',
      sharedCounterId: SOURCE,
      baseline: 0,
      maxCount: 5,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(member);

    await deleteCounterWithUnlink(SOURCE);

    const board = await db.boards.get(BOARD);
    expect(board?.completedLineIds).not.toContain('row_0');

    const sourceTask = await db.tasks.get(SOURCE);
    expect(sourceTask?.isDeleted).toBe(true);
    // Tombstoned, not physically removed (Board-integrity PR-1).
    const sourcePlacements = await db.boardTasks.where('taskId').equals(SOURCE).toArray();
    expect(sourcePlacements).toHaveLength(1);
    expect(sourcePlacements[0].isDeleted).toBe(true);

    // The member is unlinked (standalone) but NOT deleted — unlink keeps it.
    const unlinkedMember = await db.tasks.get(member.id);
    expect(unlinkedMember?.isDeleted).toBe(false);
    expect(unlinkedMember?.sharedCounterId).toBeNull();
  });
});

describe('deleteTaskWithCascade — window-stamped derived members (B2 §Member rules deletion)', () => {
  /**
   * A per-window derived counter is an artifact of the board it was minted
   * for, not library content: when its root goes, it must go too (with its
   * placement), instead of lingering as a linked row pointing at a deleted
   * root. An ORDINARY hub-derived member is untouched here — the unlink
   * policy for those lives in `deleteCounterWithUnlink`.
   */
  function derivedMember(id: string, rootId: string, over: Partial<Task> = {}): Task {
    return {
      id,
      userId: USER,
      title: 'Run 5 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 5,
      sharedCounterId: rootId,
      baseline: 0,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      startDate: START,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
      ...over,
    } as Task;
  }

  it('soft-deletes the root’s window-stamped derived counters (+ their placements, each with a sync row) and leaves an ordinary member alone', async () => {
    const ROOT = uuid(40);
    const DERIVED = uuid(41);
    const ORDINARY = uuid(42);
    const BOARD = uuid(43);

    await db.tasks.add(derivedMember(ROOT, '', { sharedCounterId: undefined, startDate: undefined, createdInWizard: undefined, isCounter: true, title: 'Root' }));
    await db.tasks.add(derivedMember(DERIVED, ROOT));
    // Same index, no window stamp — a hand-made linked counter.
    await db.tasks.add(derivedMember(ORDINARY, ROOT, { startDate: undefined, createdInWizard: undefined }));

    await db.boards.add({
      id: BOARD,
      userId: USER,
      name: 'W',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    } as Board);
    await db.boardTasks.add({
      id: `bt-${DERIVED}`,
      boardId: BOARD,
      taskId: DERIVED,
      row: 1,
      col: 1,
      isCenter: false,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    } as BoardTask);

    await deleteTaskWithCascade(ROOT);

    const derived = await db.tasks.get(DERIVED);
    expect(derived?.isDeleted).toBe(true);
    expect(derived?.version).toBe(2);
    const derivedQueue = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === DERIVED,
    );
    expect(derivedQueue).toHaveLength(1);

    const placement = await db.boardTasks.get(`bt-${DERIVED}`);
    expect(placement?.isDeleted).toBe(true);
    expect(
      (await db.syncQueue.toArray()).filter(
        (i) => i.entityType === 'boardTasks' && i.entityId === `bt-${DERIVED}`,
      ),
    ).toHaveLength(1);

    // The ordinary linked member survives the root's deletion untouched.
    const ordinary = await db.tasks.get(ORDINARY);
    expect(ordinary?.isDeleted).toBe(false);
    expect(ordinary?.version).toBe(1);
  });

  it('re-derives that board through deleteCounterWithUnlink too (final-review item 10)', async () => {
    // The hub's "delete this counter" path retires the window-stamped
    // members ITSELF, before the cascade runs — so the cascade's own
    // step-4b lookup finds nothing left to fold, and without the caller
    // handing those boards over they would never re-derive in-transaction.
    const ROOT = uuid(60);
    const DERIVED = uuid(61);
    const [B, C] = [uuid(62), uuid(63)];
    const BOARD = uuid(64);

    await db.tasks.add(
      derivedMember(ROOT, '', {
        sharedCounterId: undefined,
        startDate: undefined,
        createdInWizard: undefined,
        isCounter: true,
        title: 'Root',
      }),
    );
    await db.tasks.add(derivedMember(DERIVED, ROOT, { isCompleted: true }));
    await seedWindowedCompleteTask(B);
    await seedWindowedCompleteTask(C);
    await seedBoardWithCompletedRow0(BOARD, [DERIVED, B, C]);

    await deleteCounterWithUnlink(ROOT);

    expect((await db.tasks.get(DERIVED))?.isDeleted).toBe(true);
    const board = await db.boards.get(BOARD);
    expect(board?.completedLineIds).not.toContain('row_0');
    expect(board?.completedTasks).toBe(2);
    expect(await boardSyncEntries(BOARD)).toHaveLength(1);
  });

  it('re-derives the board that carried the retired derived counter (its bingo line cannot keep glowing)', async () => {
    const ROOT = uuid(50);
    const DERIVED = uuid(51);
    const [B, C] = [uuid(52), uuid(53)];
    const BOARD = uuid(54);

    await db.tasks.add(derivedMember(ROOT, '', { sharedCounterId: undefined, startDate: undefined, createdInWizard: undefined, title: 'Root' }));
    // The derived member reads its lifetime cache (the WC carve-out), so a
    // completed derived square needs no event.
    await db.tasks.add(derivedMember(DERIVED, ROOT, { isCompleted: true }));
    await seedWindowedCompleteTask(B);
    await seedWindowedCompleteTask(C);
    await seedBoardWithCompletedRow0(BOARD, [DERIVED, B, C]);

    await deleteTaskWithCascade(ROOT);

    const board = await db.boards.get(BOARD);
    expect(board?.completedLineIds).not.toContain('row_0');
    expect(board?.completedTasks).toBe(2);
  });
});
