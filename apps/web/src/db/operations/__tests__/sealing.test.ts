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
import { sealBoard, runBackstopAutoSeal, reDeriveSealedBoardsForTasks } from '../sealing';
import { applyTaskEventsBatch } from '../taskEventPull';
import { runMigrationV14 } from '../migrationV14';

/**
 * Windowed Completion PR C — board sealing engine (docs/WINDOWED_COMPLETION.md
 * §Sealing + §Testing matrix sealing rows). Covers: the seal transaction
 * (snapshot stored, idempotent); the backstop keyed off max(endDate,
 * activatedAt) incl. the draft-grace rule; migration sealing; fan-out
 * exclusion (a live event doesn't repaint a sealed board); re-derivation
 * determinism (late pre-seal event updates sealed pixels; same union → same
 * snapshot).
 */

const USER = 'user-1';
const H = 60 * 60 * 1000;

// A daily window: start 07-01, end 07-02 → backstop 6h → deadline 07-02T06:00.
const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-02T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';
const PAST_BACKSTOP = '2026-07-02T07:00:00.000Z'; // > end + 6h

const TASK_A = '10000000-0000-4000-8000-000000000001';
const TASK_B = '10000000-0000-4000-8000-000000000002';
const BOARD_SEALED = '20000000-0000-4000-8000-000000000001';
const BOARD_LIVE = '20000000-0000-4000-8000-000000000002';
// Event ids must be UUIDs — applyTaskEventsBatch validates via TaskEventSchema.
const EV1 = '30000000-0000-4000-8000-000000000001';
const EV2 = '30000000-0000-4000-8000-000000000002';

async function boardSyncQueueEntries(boardId: string) {
  return (await db.syncQueue.toArray()).filter(
    (i) => i.entityType === 'boards' && i.entityId === boardId,
  );
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedNormalTask(id: string, isCompleted = false, completedAt?: string): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted,
    completedAt,
    totalCompletions: isCompleted ? 1 : 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 3,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedCountingTask(id: string, maxCount: number): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'C',
    type: TaskType.COUNTING,
    maxCount,
    action: 'Do',
    unit: 'reps',
    isCompleted: false,
    currentCount: 0,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 3,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

function incrementEvent(id: string, taskId: string, delta: number, occurredAt: string, isDeleted = false): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted,
  };
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    endDate: END,
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
    ...over,
  };
  await db.boards.put(board);
  return board;
}

async function placeTask(boardId: string, taskId: string, cell: number): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: Math.floor(cell / 3),
    col: cell % 3,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
  };
  await db.boardTasks.add(bt);
}

function completionEvent(id: string, taskId: string, occurredAt: string, isDeleted = false): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted,
  };
}

// ─── seal transaction ─────────────────────────────────────────────────────────

describe('sealBoard', () => {
  it('freezes the snapshot from the in-window event union and stamps sealedAt', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await db.taskEvents.add(completionEvent('e1', TASK_A, IN_WINDOW));

    const sealed = await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    expect(sealed).toBe(true);

    const board = await db.boards.get(BOARD_SEALED);
    expect(board?.sealedAt).toBe(PAST_BACKSTOP);
    expect(board?.sealedCompletedCells).toEqual([0]);
    expect(board?.completedTasks).toBe(1);
    expect(board?.version).toBe(2); // authored write → version bump
    // status untouched by sealing.
    expect(board?.status).toBe(BoardStatus.ACTIVE);

    // A Board sync UPDATE was enqueued.
    expect(await boardSyncQueueEntries(BOARD_SEALED)).not.toHaveLength(0);
  });

  it('is idempotent — sealing an already-sealed board is a no-op', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await db.taskEvents.add(completionEvent('e1', TASK_A, IN_WINDOW));

    await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    const first = await db.boards.get(BOARD_SEALED);

    const again = await sealBoard(BOARD_SEALED, '2026-07-03T00:00:00.000Z');
    expect(again).toBe(false);
    const second = await db.boards.get(BOARD_SEALED);
    expect(second?.sealedAt).toBe(first?.sealedAt); // unchanged
    expect(second?.version).toBe(first?.version);
  });

  it('excludes post-seal events from the frozen snapshot (upper bound = sealedAt)', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    // Event AFTER the seal instant — belongs to a later window, must not count.
    await db.taskEvents.add(completionEvent('e-late', TASK_A, '2026-07-05T00:00:00.000Z'));

    await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    const board = await db.boards.get(BOARD_SEALED);
    expect(board?.sealedCompletedCells).toEqual([]);
    expect(board?.completedTasks).toBe(0);
  });

  // ── M-3: counting (delta) seal-snapshot cases (slice 1 covered only NORMAL) ──
  it('counting: freezes green when in-window increments reach the goal', async () => {
    await seedCountingTask(TASK_A, 3);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await db.taskEvents.add(incrementEvent('ec1', TASK_A, 2, IN_WINDOW));
    await db.taskEvents.add(incrementEvent('ec2', TASK_A, 1, '2026-07-01T13:00:00.000Z'));

    await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    const board = await db.boards.get(BOARD_SEALED);
    expect(board?.sealedCompletedCells).toEqual([0]);
    expect(board?.completedTasks).toBe(1);
  });

  it('counting: freezes grey when in-window sum falls short of the goal', async () => {
    await seedCountingTask(TASK_A, 3);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await db.taskEvents.add(incrementEvent('ec1', TASK_A, 2, IN_WINDOW)); // 2 < 3
    // A pre-window increment must not carry over into the sealed snapshot.
    await db.taskEvents.add(incrementEvent('ec-pre', TASK_A, 5, '2026-06-28T00:00:00.000Z'));

    await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    const board = await db.boards.get(BOARD_SEALED);
    expect(board?.sealedCompletedCells).toEqual([]);
    expect(board?.completedTasks).toBe(0);
  });

  it('counting: re-derivation flips a sealed counting square green when a late pre-seal increment arrives', async () => {
    await seedCountingTask(TASK_A, 3);
    await seedBoard(BOARD_SEALED);
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await db.taskEvents.add(incrementEvent('ec1', TASK_A, 2, IN_WINDOW));
    await sealBoard(BOARD_SEALED, PAST_BACKSTOP);
    expect((await db.boards.get(BOARD_SEALED))?.sealedCompletedCells).toEqual([]); // 2 < 3

    // A late-arriving pre-seal increment (occurredAt inside the sealed window)
    // lands and pushes the window sum to the goal → re-derivation paints green.
    await db.taskEvents.add(incrementEvent('ec-late', TASK_A, 1, '2026-07-01T14:00:00.000Z'));
    await reDeriveSealedBoardsForTasks([TASK_A]);

    const board = await db.boards.get(BOARD_SEALED);
    expect(board?.sealedCompletedCells).toEqual([0]);
    expect(board?.completedTasks).toBe(1);
    // Local-only re-derivation — no version bump vs the seal write (still 2).
    expect(board?.version).toBe(2);
  });
});

// ─── backstop auto-seal ─────────────────────────────────────────────────────────

describe('runBackstopAutoSeal', () => {
  it('seals boards past their backstop deadline and leaves in-window boards alone', async () => {
    await seedBoard(BOARD_SEALED, { endDate: END }); // deadline 07-02T06:00
    await seedBoard(BOARD_LIVE, {
      startDate: '2026-07-02T00:00:00.000Z',
      endDate: '2026-07-03T00:00:00.000Z', // deadline 07-03T06:00 — still future
    });

    const ids = await runBackstopAutoSeal(USER, PAST_BACKSTOP);
    expect(ids).toEqual([BOARD_SEALED]);

    expect((await db.boards.get(BOARD_SEALED))?.sealedAt).toBe(PAST_BACKSTOP);
    expect((await db.boards.get(BOARD_LIVE))?.sealedAt).toBeUndefined();
  });

  it('respects the draft-grace rule — activatedAt after window expiry defers the backstop', async () => {
    // Window ended 07-02, but the draft was only activated 07-04.
    const activatedAt = '2026-07-04T00:00:00.000Z';
    await seedBoard(BOARD_SEALED, { endDate: END, activatedAt });

    // At 07-02T07:00 (past endDate+6h) the grace cycle keeps it unsealed.
    const early = await runBackstopAutoSeal(USER, PAST_BACKSTOP);
    expect(early).toEqual([]);
    expect((await db.boards.get(BOARD_SEALED))?.sealedAt).toBeUndefined();

    // Only past activatedAt + 6h does it auto-seal.
    const late = await runBackstopAutoSeal(USER, '2026-07-04T07:00:00.000Z');
    expect(late).toEqual([BOARD_SEALED]);
    expect((await db.boards.get(BOARD_SEALED))?.sealedAt).toBe('2026-07-04T07:00:00.000Z');
  });

  it('never seals a draft board', async () => {
    await seedBoard(BOARD_SEALED, { status: BoardStatus.DRAFT, endDate: END });
    const ids = await runBackstopAutoSeal(USER, PAST_BACKSTOP);
    expect(ids).toEqual([]);
  });
});

// ─── migration sealing ─────────────────────────────────────────────────────────

describe('runMigrationV14 (expired-board sealing)', () => {
  it('seals already-expired boards from lifetime caches; leaves live boards', async () => {
    // Freeze wall-clock well past both windows so the migration sees an expired
    // board. (Board's own endDate governs the backstop, not real "now".)
    // Use a board whose deadline is in the past relative to real time by
    // giving it an ancient window.
    const ancientStart = '2020-01-01T00:00:00.000Z';
    const ancientEnd = '2020-01-02T00:00:00.000Z';
    await seedNormalTask(TASK_A, true, ancientStart); // lifetime-complete
    await seedBoard(BOARD_SEALED, { startDate: ancientStart, endDate: ancientEnd });
    await placeTask(BOARD_SEALED, TASK_A, 0);

    // A live board far in the future — not past its backstop.
    const future = new Date(Date.now() + 30 * 24 * H).toISOString();
    const futureEnd = new Date(Date.now() + 60 * 24 * H).toISOString();
    await seedBoard(BOARD_LIVE, { startDate: future, endDate: futureEnd });

    await runMigrationV14({} as never);

    const sealed = await db.boards.get(BOARD_SEALED);
    expect(sealed?.sealedAt).toBeTruthy();
    // Lifetime rendered state: TASK_A isCompleted → cell 0 green.
    expect(sealed?.sealedCompletedCells).toEqual([0]);
    expect(sealed?.completedTasks).toBe(1);

    expect((await db.boards.get(BOARD_LIVE))?.sealedAt).toBeUndefined();
  });
});

// ─── fan-out exclusion ─────────────────────────────────────────────────────────

describe('fan-out exclusion (a live event does not repaint a sealed board)', () => {
  it('a shared task changing on a live board does not mutate the sealed board snapshot', async () => {
    await seedNormalTask(TASK_A);
    // Sealed board places TASK_A at cell 0, sealed with it grey.
    await seedBoard(BOARD_SEALED, { sealedAt: PAST_BACKSTOP, sealedCompletedCells: [] });
    await placeTask(BOARD_SEALED, TASK_A, 0);
    // Live board (a later window) also places TASK_A.
    await seedBoard(BOARD_LIVE, {
      startDate: '2026-07-02T00:00:00.000Z',
      endDate: '2026-07-03T00:00:00.000Z',
    });
    await placeTask(BOARD_LIVE, TASK_A, 0);

    // A live completion arrives for TASK_A in the LIVE window via pull.
    await applyTaskEventsBatch(USER, [
      completionEvent(EV1, TASK_A, '2026-07-02T12:00:00.000Z'),
    ]);

    // Live board repaints; sealed board's frozen snapshot is unchanged.
    const live = await db.boards.get(BOARD_LIVE);
    expect(live?.completedTasks).toBe(1);
    const sealed = await db.boards.get(BOARD_SEALED);
    expect(sealed?.sealedCompletedCells).toEqual([]);
    expect(sealed?.completedTasks).toBe(0);
  });
});

// ─── pull-path seal re-derivation ────────────────────────────────────────────────

describe('reDeriveSealedBoardsForTasks (late pre-seal event convergence)', () => {
  it('a late pre-seal event re-derives the sealed board green (deterministic)', async () => {
    await seedNormalTask(TASK_A);
    // Sealed board grey at seal time (event hadn't arrived).
    await seedBoard(BOARD_SEALED, { sealedAt: PAST_BACKSTOP, sealedCompletedCells: [] });
    await placeTask(BOARD_SEALED, TASK_A, 0);

    // A device that was offline logged completion IN the sealed window; it now
    // arrives via pull.
    await applyTaskEventsBatch(USER, [completionEvent(EV2, TASK_A, IN_WINDOW)]);

    const sealed = await db.boards.get(BOARD_SEALED);
    expect(sealed?.sealedCompletedCells).toEqual([0]);
    expect(sealed?.completedTasks).toBe(1);
    // Re-derivation is local-only: version NOT bumped, no board sync enqueued.
    expect(sealed?.version).toBe(1);
    expect(await boardSyncQueueEntries(BOARD_SEALED)).toHaveLength(0);
  });

  it('a post-seal event does NOT bleed into the sealed board on re-derivation', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(BOARD_SEALED, { sealedAt: PAST_BACKSTOP, sealedCompletedCells: [] });
    await placeTask(BOARD_SEALED, TASK_A, 0);

    // Event occurs AFTER the seal instant → outside [startDate, sealedAt].
    await db.taskEvents.add(completionEvent('e-after', TASK_A, '2026-07-10T00:00:00.000Z'));
    await reDeriveSealedBoardsForTasks([TASK_A]);

    const sealed = await db.boards.get(BOARD_SEALED);
    expect(sealed?.sealedCompletedCells).toEqual([]);
    expect(sealed?.completedTasks).toBe(0);
  });

  it('re-derivation is idempotent / order-independent (same union → same snapshot)', async () => {
    await seedNormalTask(TASK_A);
    await seedNormalTask(TASK_B);
    await seedBoard(BOARD_SEALED, { sealedAt: PAST_BACKSTOP, sealedCompletedCells: [] });
    await placeTask(BOARD_SEALED, TASK_A, 0);
    await placeTask(BOARD_SEALED, TASK_B, 1);
    await db.taskEvents.add(completionEvent('e-a', TASK_A, IN_WINDOW));
    await db.taskEvents.add(completionEvent('e-b', TASK_B, '2026-07-01T18:00:00.000Z'));

    await reDeriveSealedBoardsForTasks([TASK_A, TASK_B]);
    const once = await db.boards.get(BOARD_SEALED);
    await reDeriveSealedBoardsForTasks([TASK_B, TASK_A]); // reversed order
    const twice = await db.boards.get(BOARD_SEALED);

    expect(once?.sealedCompletedCells).toEqual([0, 1]);
    expect(twice?.sealedCompletedCells).toEqual(once?.sealedCompletedCells);
  });
});
