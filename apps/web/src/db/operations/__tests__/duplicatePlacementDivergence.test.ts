import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  resolvePlacements,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { addBoardTaskToBoard } from '../boardTasks';
import { computeBoardStatsUpdate } from '@oybc/shared';

/**
 * FIXED-BEHAVIOR REGRESSION SUITE — duplicate BoardTask placement rows.
 *
 * History: this file started as DIAGNOSTIC EVIDENCE (pre board-integrity
 * PR-1/PR-2) proving that a corrupted board (duplicate BoardTask rows — same
 * task at two positions, or two different tasks at one position) made the
 * RENDER layer (`useBoardPlayData`'s `btByPosition`) disagree with the
 * DERIVATION layer (`computeBoardStatsUpdate` / `computeBoardGrid`) about
 * which cells are complete — up to and including a false whole-board
 * GREENLOG. Every fixture here is still deliberately corrupted via direct
 * `db.*.add` calls (bypassing the write-path guards PR-2 Part 3 added) —
 * that corruption is exactly the pre-tombstone-era / offline-sync-union
 * shape PR-2's repair pass (Part 1) exists to clean up, and the shape
 * PR-2's deterministic resolver (Part 2) exists to make readers agree about
 * EVEN BEFORE repair catches up.
 *
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md) fixed the divergence this
 * file diagnosed:
 *   - Part 2 — `resolvePlacements` (the shared winner rule: highest version
 *     -> newest updatedAt -> lowest id) is now the ROW-SET every reader
 *     funnels through: `useBoardPlayData`'s `btByPosition`/`boardTasks`
 *     (which `seedEditDraft` seeds from), and the derivation-input assembly
 *     at every cascade site (`addBoardTaskToBoard` included). Render and
 *     derivation can no longer pick DIFFERENT winners for a colliding cell.
 *   - Part 3 — `addBoardTaskToBoard`/`createBoardTask` now reject (throw) a
 *     placement that would collide with a live cell, duplicate a task
 *     already on the board, or fall outside the grid — going forward, this
 *     corruption shape cannot be written by any production path (only
 *     direct `db.*.add`, as this file still does, to simulate legacy data).
 *   - Part 1 — `repairPlacementIntegrity` (`placementIntegrity.ts`) cleans
 *     up ALREADY-corrupted boards on app-open; see
 *     `placementIntegrity.test.ts` for that pass's own dedicated suite.
 *
 * This file keeps its original Case A / Case B structure and history
 * comments (updated where the finding itself changed) so the diagnostic
 * trail stays legible — only the ASSERTIONS were flipped to pin the FIXED
 * behavior.
 */

const WINDOW_START = '2026-06-01T00:00:00.000Z';
const IN_WINDOW = '2026-06-05T12:00:00.000Z';

async function seedTask(
  id: string,
  opts: { completed: boolean; withEvent?: boolean } = { completed: true },
): Promise<void> {
  const task: Task = {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: opts.completed,
    completedAt: opts.completed ? IN_WINDOW : undefined,
    totalCompletions: opts.completed ? 1 : 0,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: IN_WINDOW,
    version: 2,
    isDeleted: false,
  };
  await db.tasks.add(task);
  if (opts.completed && opts.withEvent !== false) {
    const event: TaskEvent = {
      id: `evt-${id}`,
      userId: 'user-1',
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
}

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Corrupted board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: WINDOW_START,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedPlacement(id: string, taskId: string, row: number, col: number): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId: 'board-1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

/**
 * FIXED replica of `useBoardPlayData`'s render-position dict
 * (apps/web/src/hooks/useBoardPlayData.ts) — now runs the raw query result
 * through the shared `resolvePlacements` winner rule BEFORE building the
 * position dict, exactly like the production hook does post-PR-2. This is
 * the direct fix for the pre-PR-2 replica below (kept in history only via
 * this comment): the old version sorted by (row, col) and let a stable-sort
 * "last write wins" fall out of Dexie's incidental id-ascending query
 * order — an implementation accident, not a real rule. `resolvePlacements`
 * makes the winner explicit, shared, and vector-pinned.
 */
function computeBtByPosition(boardTasks: BoardTask[], boardSize: number): Record<string, BoardTask> {
  const resolved = resolvePlacements(boardTasks, boardSize);
  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of resolved) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }
  return btByPosition;
}

async function queryBoardTasks(boardId: string): Promise<BoardTask[]> {
  return db.boardTasks.where('boardId').equals(boardId).toArray();
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('Duplicate BoardTask placement — ground truth: query ordering', () => {
  it('db.boardTasks.where(boardId).equals(...).toArray() returns rows ascending by id, NOT insertion order', async () => {
    await seedBoard();
    await seedTask('task-A', { completed: true });
    // Insert 'bt-z' (lexicographically LAST) BEFORE 'bt-a' (lexicographically
    // FIRST) — if the query preserved insertion order, we'd see [bt-z, bt-a].
    await seedPlacement('bt-z', 'task-A', 0, 0);
    await seedPlacement('bt-a', 'task-A', 1, 1);

    const rows = await queryBoardTasks('board-1');
    // Still true post-PR-2 — this is a Dexie/IndexedDB fact, not application
    // behavior this fix changes. It's WHY the pre-fix render dict picked an
    // arbitrary winner (whichever row query-sorted last for a given cell):
    // the fix (Part 2) replaces that implementation accident with an
    // explicit, shared winner rule (`resolvePlacements`) instead of relying
    // on it.
    expect(rows.map((r) => r.id)).toEqual(['bt-a', 'bt-z']);
  });
});

describe('Case A — same taskId placed at two DIFFERENT (non-colliding) positions', () => {
  it('both cells render the same task+state as derivation — NO per-cell visual divergence when the two positions do not collide', async () => {
    await seedBoard();
    await seedTask('task-A', { completed: true });
    await seedTask('task-B', { completed: true });
    await seedTask('task-C', { completed: true });
    // task-A has a "stale old row" at (0,0) and a "current row" at (2,2).
    // Neither cell is contested by any other row.
    await seedPlacement('bt-A-old', 'task-A', 0, 0);
    await seedPlacement('bt-A-new', 'task-A', 2, 2);
    await seedPlacement('bt-B', 'task-B', 0, 1);
    await seedPlacement('bt-C', 'task-C', 0, 2);

    const boardTasks = await queryBoardTasks('board-1');
    const btByPosition = computeBtByPosition(boardTasks, 3);

    // UNCHANGED finding: `resolvePlacements` only collapses PER-CELL
    // collisions (Part 2's stated scope — "this PR only unifies the ROW-SET
    // selection"); it does not dedupe a task placed at two non-colliding
    // cells (that's a board-wide invariant, not a per-cell rendering
    // concern — see `computePlacementIntegrityRepair`, which DOES treat
    // this as a violation, in placementIntegrity.test.ts). So both cells
    // still render task-A — exactly what derivation would also compute for
    // both. This specific shape was never the render/derivation divergence
    // (that requires a COLLISION — see Case A+collision and Case B below).
    //
    // Going forward this specific shape (one task, two live placements on
    // the SAME board) can no longer be WRITTEN by any production path —
    // `addBoardTaskToBoard`/`createBoardTask` (PR-2 Part 3) reject a task
    // already placed on the board — and an app-open repair pass (Part 1)
    // collapses any pre-existing instance of it down to one survivor. This
    // test still seeds it via direct `db.*.add` (bypassing those guards) to
    // pin what a not-yet-repaired legacy board renders like in the
    // meantime.
    expect(btByPosition['0-0'].taskId).toBe('task-A');
    expect(btByPosition['2-2'].taskId).toBe('task-A');
  });

  it('CORRECTION: completedTasks is NOT inflated by a non-colliding duplicate — it still equals the count of genuinely filled+complete cells', async () => {
    // This test started life asserting the opposite (double-counted stat)
    // and FAILED against real derivation output even pre-PR-2 — the
    // assumption was wrong, and the failure was itself part of the original
    // diagnostic evidence. Unaffected by PR-2 (no collision here — see the
    // reasoning above), so the finding and the assertions are unchanged;
    // only the input now explicitly passes through `resolvePlacements`
    // (a no-op here, since there is no collision to collapse) to match the
    // production cascade's actual input-assembly shape.
    const board = await seedBoard();
    await seedTask('task-A', { completed: true }); // occupies 2 of the 9 cells
    await seedPlacement('bt-A-old', 'task-A', 0, 0);
    await seedPlacement('bt-A-new', 'task-A', 2, 2);
    // 7 more distinct complete tasks fill the remaining 7 cells.
    const remaining: Array<[number, number]> = [
      [0, 1], [0, 2], [1, 0], [1, 1], [1, 2], [2, 0], [2, 1],
    ];
    for (let i = 0; i < remaining.length; i++) {
      const id = `task-fill-${i}`;
      await seedTask(id, { completed: true });
      await seedPlacement(`bt-fill-${i}`, id, remaining[i][0], remaining[i][1]);
    }

    const boardTasksOnBoard = resolvePlacements(await queryBoardTasks('board-1'), board.boardSize);
    // 9 grid cells, 9 BoardTask rows survive resolution — task-A supplies 2
    // of the 9 rows, but there is NO collision, so row-count === filled-cell-count.
    expect(boardTasksOnBoard.length).toBe(9);
    const distinctCells = new Set(boardTasksOnBoard.map((r) => `${r.row}-${r.col}`));
    expect(distinctCells.size).toBe(9);

    const taskById: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskById[t.id] = t;
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    for (const e of await db.taskEvents.toArray()) {
      (eventsByTaskId[e.taskId] ??= []).push(e);
    }

    const stats = computeBoardStatsUpdate(board, boardTasksOnBoard, {}, taskById, [board], {
      eventsByTaskId,
    });

    // NOT inflated: matches the 9 physically filled, genuinely-green cells.
    expect(stats.completedTasks).toBe(9);
    expect(stats.completedTasks).toBe(board.boardSize * board.boardSize);
  });
});

describe('Case A + collision — the full hypothesis narrative (FIXED by resolvePlacements)', () => {
  it('render and derivation now AGREE on which task occupies the collided cell — no more phantom bingo line', async () => {
    const board = await seedBoard();
    // task-A: complete, "current" position at (2,2) — irrelevant to this test,
    // included to match the "stale old row + current row" framing.
    await seedTask('task-A', { completed: true });
    await seedPlacement('bt-A-new', 'task-A', 2, 2);
    // task-D: INCOMPLETE — the task the user actually replaced (0,0) with.
    await seedTask('task-D', { completed: false });
    // Collision at (0,0): task-A's stale old row AND task-D's current row.
    // Both rows share the same version(1)/updatedAt (fixture-fixed), so the
    // winner rule falls through to the id tie-break: 'bt-a-old' < 'bt-d-new'
    // lexicographically -> task-A (the OLDER row) wins under `resolvePlacements`.
    // This is the OPPOSITE of the pre-fix render pick (which, via the
    // ground-truth query-order accident, showed task-D) — but the headline
    // fix isn't WHICH row wins; it's that render and derivation now pick
    // the SAME one, always.
    await seedPlacement('bt-a-old', 'task-A', 0, 0);
    await seedPlacement('bt-d-new', 'task-D', 0, 0);
    // Complete row 0's other two cells so row_0 is a bingo IFF (0,0) counts complete.
    await seedTask('task-B', { completed: true });
    await seedTask('task-C', { completed: true });
    await seedPlacement('bt-B', 'task-B', 0, 1);
    await seedPlacement('bt-C', 'task-C', 0, 2);

    const rawBoardTasks = await queryBoardTasks('board-1');
    const btByPosition = computeBtByPosition(rawBoardTasks, board.boardSize);

    // RENDER: (0,0) shows task-A (the winner rule's pick), which is COMPLETE.
    expect(btByPosition['0-0'].taskId).toBe('task-A');

    const taskById: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskById[t.id] = t;
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    for (const e of await db.taskEvents.toArray()) {
      (eventsByTaskId[e.taskId] ??= []).push(e);
    }

    // FIXED derivation input assembly (Part 2): every production cascade
    // site now resolves through the SAME winner rule before calling
    // `computeBoardStatsUpdate` — reproduced explicitly here since this
    // test drives the kernel directly rather than through a cascade.
    const resolvedBoardTasks = resolvePlacements(rawBoardTasks, board.boardSize);
    const stats = computeBoardStatsUpdate(
      board,
      resolvedBoardTasks,
      {},
      taskById,
      [board],
      { eventsByTaskId },
    );

    // DERIVATION: row_0 IS a bingo — and now for the SAME reason render
    // shows it green: task-A (the resolved winner) is complete at (0,0).
    // FIXED: no more divergence — the persisted highlight ring for row_0
    // draws through a cell the rendered grid also shows complete.
    expect(stats.completedLineIds).toContain('row_0');
    expect(stats.linesCompleted).toBe(1);
  });

  it('reversing the id ordering of the colliding pair flips which task wins — but render and derivation flip TOGETHER, never apart', async () => {
    const board = await seedBoard();
    await seedTask('task-A', { completed: true });
    await seedTask('task-D', { completed: false });
    await seedTask('task-B', { completed: true });
    await seedTask('task-C', { completed: true });
    // Arrangement 1: task-A's row id sorts BEFORE task-D's ('bt-x-a-old' < 'bt-y-d-new')
    // -> task-A (complete) wins the winner-rule pick at (0,0).
    await seedPlacement('bt-x-a-old', 'task-A', 0, 0);
    await seedPlacement('bt-y-d-new', 'task-D', 0, 0);
    await seedPlacement('bt-B', 'task-B', 0, 1);
    await seedPlacement('bt-C', 'task-C', 0, 2);

    const taskById: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskById[t.id] = t;
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    for (const e of await db.taskEvents.toArray()) {
      (eventsByTaskId[e.taskId] ??= []).push(e);
    }

    const rawBoardTasks1 = await queryBoardTasks('board-1');
    const btByPosition1 = computeBtByPosition(rawBoardTasks1, board.boardSize);
    expect(btByPosition1['0-0'].taskId).toBe('task-A');
    const resolved1 = resolvePlacements(rawBoardTasks1, board.boardSize);
    const stats1 = computeBoardStatsUpdate(board, resolved1, {}, taskById, [board], { eventsByTaskId });
    // Render shows task-A (complete) AND derivation agrees: row_0 is a bingo.
    expect(stats1.completedLineIds).toContain('row_0');

    // Arrangement 2: SAME two tasks, SAME cell, only the row ids are swapped
    // so task-D's row now sorts BEFORE task-A's ('bt-1-d-new' < 'bt-2-a-old').
    await db.boardTasks.clear();
    await seedPlacement('bt-1-d-new', 'task-D', 0, 0);
    await seedPlacement('bt-2-a-old', 'task-A', 0, 0);
    await seedPlacement('bt-B-2', 'task-B', 0, 1);
    await seedPlacement('bt-C-2', 'task-C', 0, 2);
    const rawBoardTasks2 = await queryBoardTasks('board-1');
    const btByPosition2 = computeBtByPosition(rawBoardTasks2, board.boardSize);
    // This time the winner rule picks task-D (INCOMPLETE) — the id
    // tie-break is still an arbitrary-w.r.t.-user-action pick (a known,
    // accepted trait shared with the sync layer's own LWW tie-break, not a
    // bug this PR claims to remove) — but it is now the SAME pick
    // derivation makes, which is the actual fix.
    expect(btByPosition2['0-0'].taskId).toBe('task-D');
    const resolved2 = resolvePlacements(rawBoardTasks2, board.boardSize);
    const stats2 = computeBoardStatsUpdate(board, resolved2, {}, taskById, [board], { eventsByTaskId });
    // FIXED: derivation now agrees with render — task-D (incomplete) is the
    // only row counted for (0,0), so row_0 is NOT a bingo. Pre-PR-2, this
    // arrangement's derivation ran over ALL rows (task-A included) and
    // reported row_0 complete regardless of which task rendered — the exact
    // divergence this PR closes.
    expect(stats2.completedLineIds).not.toContain('row_0');
  });
});

describe('Case B — two different tasks, one position, real cascade (addBoardTaskToBoard) — FIXED', () => {
  it('a pre-existing collision elsewhere on the board no longer falsely GREENLOGs an ordinary "add task to empty cell" action', async () => {
    // 3x3 board. Fill 7 of 9 cells with distinct complete tasks, and leave
    // (2,1) as a COLLISION of two DIFFERENT complete tasks (both complete —
    // deliberately, so no single cell "looks" wrong), and (2,2) genuinely
    // EMPTY (no row at all yet). This corruption shape can no longer be
    // WRITTEN by `addBoardTaskToBoard`/`createBoardTask` (Part 3 rejects a
    // second live row at an occupied cell) — seeded via direct `db.*.add`
    // to simulate a legacy/pre-repair board.
    const board = await seedBoard();
    const positions: Array<[number, number]> = [
      [0, 0], [0, 1], [0, 2],
      [1, 0], [1, 1], [1, 2],
      [2, 0],
    ];
    for (let i = 0; i < positions.length; i++) {
      const id = `task-${i}`;
      await seedTask(id, { completed: true });
      await seedPlacement(`bt-${i}`, id, positions[i][0], positions[i][1]);
    }
    // Collision at (2,1): two distinct complete tasks, two rows, one cell.
    await seedTask('task-collide-1', { completed: true });
    await seedTask('task-collide-2', { completed: true });
    await seedPlacement('bt-collide-1', 'task-collide-1', 2, 1);
    await seedPlacement('bt-collide-2', 'task-collide-2', 2, 1);
    // (2,2) intentionally left with NO row — a genuinely empty cell.

    const preTasks = await queryBoardTasks('board-1');
    expect(preTasks.length).toBe(9); // 7 + 2 colliding rows at ONE of the 9 cells
    const distinctCellsPre = new Set(preTasks.map((r) => `${r.row}-${r.col}`));
    expect(distinctCellsPre.size).toBe(8); // only 8 of 9 cells are actually occupied

    // A completely ordinary user action: add a fresh, INCOMPLETE task to the
    // one truly-empty cell via the REAL production cascade
    // (`addBoardTaskToBoard`, apps/web/src/db/operations/boardTasks.ts) —
    // not a synthetic derivation call. PR-2's write-path guards (Part 3)
    // don't block this: (2,2) is genuinely empty and task-new-incomplete
    // isn't already on the board — the pre-existing corruption is
    // elsewhere, at (2,1).
    await seedTask('task-new-incomplete', { completed: false });
    await addBoardTaskToBoard('board-1', 'task-new-incomplete', 2, 2);

    const boardAfter = await db.boards.get('board-1');
    expect(boardAfter).toBeDefined();

    const allTasksAfter = await queryBoardTasks('board-1');
    const btByPosition = computeBtByPosition(allTasksAfter, board.boardSize);
    // RENDER: (2,2) shows the just-added task, which is INCOMPLETE.
    expect(btByPosition['2-2'].taskId).toBe('task-new-incomplete');

    // FIXED (the headline result): the production cascade inside
    // `addBoardTaskToBoard` now resolves `boardTasksOnBoard` through
    // `resolvePlacements` before calling `computeBoardStatsUpdate` — the
    // (2,1) collision collapses to its ONE winner (still complete either
    // way, since both colliding tasks are complete — the collision itself
    // isn't what was wrong), so the 9 resolved rows map 1:1 onto the 9 grid
    // cells: 8 genuinely complete (7 distinct + the (2,1) winner), 1
    // genuinely incomplete (the just-added task at (2,2)).
    // `completedTasks` is now 8, NOT 9 — `isGreenlog = completedTasks >=
    // totalSquares` reads FALSE, and the board correctly stays ACTIVE.
    // Pre-PR-2, the raw (unresolved) 10-row set double-surfaced the (2,1)
    // collision as 2 separate "complete" increments against a per-CELL
    // `totalSquares` denominator, producing a false GREENLOG.
    expect(boardAfter!.completedTasks).toBe(8);
    expect(boardAfter!.status).toBe(BoardStatus.ACTIVE);
  });

  it('rejects adding a task to a cell that already has a live placement (Part 3 write-path guard)', async () => {
    await seedBoard();
    await seedTask('task-existing', { completed: true });
    await seedPlacement('bt-existing', 'task-existing', 0, 0);
    await seedTask('task-new', { completed: false });

    await expect(addBoardTaskToBoard('board-1', 'task-new', 0, 0)).rejects.toThrow(
      /already occupied/,
    );
    // No new row was written — the cell still has exactly its original occupant.
    const rows = await queryBoardTasks('board-1');
    expect(rows.filter((r) => !r.isDeleted).map((r) => r.id)).toEqual(['bt-existing']);
  });

  it('rejects adding a task that is already live elsewhere on the same board (Part 3 write-path guard)', async () => {
    await seedBoard();
    await seedTask('task-A', { completed: true });
    await seedPlacement('bt-A', 'task-A', 0, 0);

    await expect(addBoardTaskToBoard('board-1', 'task-A', 1, 1)).rejects.toThrow(
      /already placed on board/,
    );
  });

  it('rejects a placement whose row/col falls outside the board grid (Part 3 write-path guard)', async () => {
    const board = await seedBoard({ boardSize: 3 });
    await seedTask('task-oob', { completed: false });

    await expect(addBoardTaskToBoard(board.id, 'task-oob', 3, 0)).rejects.toThrow(/out of bounds/);
  });
});

describe('Board Edit seam — does entering edit mode now self-heal a duplicate at the seam? (FIXED)', () => {
  it('squaresDraft seeds from the RESOLVED boardTasks — the losing duplicate row is invisible to the draft, not doubled', async () => {
    await seedBoard();
    await seedTask('task-A', { completed: true });
    await seedTask('task-D', { completed: false });
    await seedPlacement('bt-a-old', 'task-A', 0, 0);
    await seedPlacement('bt-d-new', 'task-D', 0, 0);

    // FIXED replica of the seed effect, apps/web/src/hooks/useBoardPlay.ts's
    // `setSquaresDraft(boardTasks.map(...))` — `boardTasks` there is now
    // `useBoardPlayData`'s ALREADY-`resolvePlacements`'d output (Part 2), not
    // the raw DB rows. Reproduced here as an explicit two-step (resolve, then
    // map) to make that source-of-truth change visible in the test.
    const rawBoardTasks = await queryBoardTasks('board-1');
    const resolvedBoardTasks = resolvePlacements(rawBoardTasks, 3);
    const squaresDraft = resolvedBoardTasks.map((bt) => ({
      boardTaskId: bt.id,
      row: bt.row,
      col: bt.col,
      taskId: bt.taskId,
      originalTaskId: bt.taskId,
      originalRow: bt.row,
      originalCol: bt.col,
    }));

    // FIXED: only ONE draft cell survives at (0,0) — the winner rule's pick
    // (lowest id among the tied pair: 'bt-a-old' < 'bt-d-new' -> task-A).
    // Pre-PR-2 BOTH rows survived into the draft untouched (no dedup at
    // seed time at all); post-PR-2 the seed source itself is already
    // deduped, so the loser is never even offered to the edit surface.
    expect(squaresDraft.length).toBe(1);
    expect(squaresDraft[0].taskId).toBe('task-A');
  });

  it('commitSquareEdits\' removal diff never sees the losing duplicate — it was already excluded before the draft existed, not skipped by a no-op Save', async () => {
    await seedBoard();
    await seedTask('task-A', { completed: true });
    await seedTask('task-D', { completed: false });
    await seedPlacement('bt-a-old', 'task-A', 0, 0);
    await seedPlacement('bt-d-new', 'task-D', 0, 0);

    const rawBoardTasks = await queryBoardTasks('board-1');
    const resolvedBoardTasks = resolvePlacements(rawBoardTasks, 3);
    const squaresDraft = resolvedBoardTasks.map((bt) => ({
      boardTaskId: bt.id,
      row: bt.row,
      col: bt.col,
      taskId: bt.taskId,
      originalTaskId: bt.taskId,
      originalRow: bt.row,
      originalCol: bt.col,
    }));

    // FIXED replica of commitSquareEdits' removal diff
    // (apps/web/src/hooks/useBoardPlay.ts): both `squaresDraft` AND the
    // `boardTasks` it diffs against are now the SAME resolved set (both
    // ultimately sourced from `useBoardPlayData`'s resolved `boardTasks`),
    // so the loser row (`bt-d-new`) was never a member of either side of
    // this diff to begin with.
    const draftIds = new Set(squaresDraft.map((c) => c.boardTaskId));
    const toRemove = resolvedBoardTasks.filter((bt) => !draftIds.has(bt.id));

    // Still zero — but for a DIFFERENT, fixed reason: pre-PR-2 this was
    // zero because the diff never flagged an untouched duplicate for
    // removal (the corruption survived the edit/save round-trip). Post-PR-2
    // it's zero because the loser was already excluded from BOTH sides of
    // the diff before the draft ever existed — the live-edit surface never
    // sees it in the first place, so there's nothing for a no-op Save to
    // (fail to) remove. The row DOES still physically exist as a live,
    // un-tombstoned BoardTask in the DB at this point — cleaning that up is
    // the repair pass's job (Part 1, `placementIntegrity.ts`), not the
    // live-edit surface's; see `placementIntegrity.test.ts`.
    expect(toRemove.length).toBe(0);

    const stillLiveInDb = await db.boardTasks.get('bt-d-new');
    expect(stillLiveInDb?.isDeleted).toBe(false);
  });
});
