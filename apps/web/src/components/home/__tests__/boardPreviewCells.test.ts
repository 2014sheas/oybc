import { describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { buildBoardPreviewCells } from '../boardPreviewCells';

/**
 * `buildBoardPreviewCells` bugfix (bugfix/board-preview-real-cells): the
 * board-card mini preview must render the TRUE grid — real boardSize, real
 * BoardTask placement, real per-cell completion via the same derivation the
 * play surface uses (`taskToSquareState`) — never a first-N count fill.
 * Mirrors `apps/ios/OYBCTests/BoardPreviewCellsTests.swift` case-for-case.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';

function makeBoard(over: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
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
    ...over,
  };
}

function makeNormalTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeCountingTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Counter ${id}`,
    type: TaskType.COUNTING,
    action: 'Do',
    maxCount: 10,
    unit: 'reps',
    isCompleted: false,
    currentCount: 0,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeCompoundTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Compound ${id}`,
    type: TaskType.COMPOUND,
    operator: OperatorType.AND,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeAchievementTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Achievement ${id}`,
    type: TaskType.ACHIEVEMENT,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeBoardTask(boardId: string, taskId: string, row: number, col: number): BoardTask {
  return {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function makeCompoundChild(compoundTaskId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id: `cc-${compoundTaskId}-${childTaskId}`,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function completionEvent(id: string, taskId: string, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

describe('buildBoardPreviewCells', () => {
  it('renders real BoardTask positions, not a first-N count fill', () => {
    const board = makeBoard({ boardSize: 3, completedTasks: 1 });
    // Two tasks placed at NON-leading positions (row 2), one done, one not.
    const done = makeNormalTask('t-done', { isCompleted: true, completedAt: START });
    const notDone = makeNormalTask('t-not-done');
    const boardTasks = [makeBoardTask(board.id, done.id, 2, 0), makeBoardTask(board.id, notDone.id, 2, 2)];
    const taskMap = { [done.id]: done, [notDone.id]: notDone };
    // An in-window completion event so the windowed derivation (always in
    // effect — this board has no sealed snapshot) reads `done` as done.
    const eventsByTaskId = { [done.id]: [completionEvent('e-done', done.id, START)] };

    const { size, cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, eventsByTaskId);

    expect(size).toBe(3);
    expect(cells).toHaveLength(9);
    // First 6 cells (rows 0–1) are all empty — a count-based fill would have
    // put the one "on" cell first.
    for (let i = 0; i < 6; i++) expect(cells[i]).toEqual({ kind: 'empty' });
    expect(cells[6]).toEqual({ kind: 'task', completed: true }); // row2,col0
    expect(cells[7]).toEqual({ kind: 'empty' }); // row2,col1 — unplaced
    expect(cells[8]).toEqual({ kind: 'task', completed: false }); // row2,col2
  });

  it('empty cells render for unplaced positions', () => {
    const board = makeBoard({ boardSize: 3 });
    const { cells } = buildBoardPreviewCells(board, [], {}, {}, {});
    expect(cells).toHaveLength(9);
    expect(cells.every((c) => c.kind === 'empty')).toBe(true);
  });

  it('derives size from board.boardSize (3/4/5)', () => {
    for (const boardSize of [3, 4, 5] as const) {
      const board = makeBoard({ boardSize });
      const { size, cells } = buildBoardPreviewCells(board, [], {}, {}, {});
      expect(size).toBe(boardSize);
      expect(cells).toHaveLength(boardSize * boardSize);
    }
  });

  it('an unplaced FREE center on an odd board renders freeCenter', () => {
    const board = makeBoard({ boardSize: 3, centerSquareType: CenterSquareType.FREE });
    const { cells } = buildBoardPreviewCells(board, [], {}, {}, {});
    // 3x3 center index = row1,col1 = index 4.
    expect(cells[4]).toEqual({ kind: 'freeCenter' });
    for (let i = 0; i < 9; i++) {
      if (i !== 4) expect(cells[i]).toEqual({ kind: 'empty' });
    }
  });

  it('a CUSTOM_FREE center also renders freeCenter', () => {
    const board = makeBoard({ boardSize: 5, centerSquareType: CenterSquareType.CUSTOM_FREE });
    const { cells } = buildBoardPreviewCells(board, [], {}, {}, {});
    // 5x5 center index = row2,col2 = index 12.
    expect(cells[12]).toEqual({ kind: 'freeCenter' });
  });

  it('a NONE center with no task placed is a plain empty cell (not freeCenter)', () => {
    const board = makeBoard({ boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const { cells } = buildBoardPreviewCells(board, [], {}, {}, {});
    expect(cells[4]).toEqual({ kind: 'empty' });
  });

  it('a live board resolves an event-owning task against the window (not the lifetime cache)', () => {
    const board = makeBoard({ boardSize: 3, startDate: '2026-07-05T00:00:00.000Z' });
    // Lifetime cache says complete, but the only completion event is BEFORE
    // this board's window — should read as NOT done (bleed-green regression).
    const task = makeNormalTask('t-1', { isCompleted: true, completedAt: '2026-07-01T00:00:00.000Z' });
    const boardTasks = [makeBoardTask(board.id, task.id, 0, 0)];
    const taskMap = { [task.id]: task };
    const eventsByTaskId = { [task.id]: [completionEvent('e-1', task.id, '2026-07-01T00:00:00.000Z')] };

    const { cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, eventsByTaskId);

    expect(cells[0]).toEqual({ kind: 'task', completed: false });
  });

  it('a live board reads a fresh in-window event as done even though the lifetime cache is stale-false', () => {
    const board = makeBoard({ boardSize: 3, startDate: '2026-07-05T00:00:00.000Z' });
    const task = makeNormalTask('t-1', { isCompleted: false });
    const boardTasks = [makeBoardTask(board.id, task.id, 0, 0)];
    const taskMap = { [task.id]: task };
    const eventsByTaskId = { [task.id]: [completionEvent('e-1', task.id, '2026-07-05T09:00:00.000Z')] };

    const { cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, eventsByTaskId);

    expect(cells[0]).toEqual({ kind: 'task', completed: true });
  });

  it('a derived (shared-counter-linked) counter stays on its lifetime cache, ignoring window events', () => {
    const board = makeBoard({ boardSize: 3, startDate: '2026-07-05T00:00:00.000Z' });
    // Derived counters are carved out of windowed evaluation — isCompleted is
    // a propagation-stamped lifetime cache, never event-derived.
    const derived = makeCountingTask('t-derived', {
      isCompleted: true,
      sharedCounterId: 'source-task',
      baseline: 0,
      currentCount: 10,
    });
    const boardTasks = [makeBoardTask(board.id, derived.id, 0, 0)];
    const taskMap = { [derived.id]: derived };
    // No events at all for this task — if the code incorrectly windowed it,
    // zero events would resolve to incomplete; the carve-out must still say true.
    const { cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, {});

    expect(cells[0]).toEqual({ kind: 'task', completed: true });
  });

  it('a compound task evaluates via its operator against its (windowed) children', () => {
    const board = makeBoard({ boardSize: 3, startDate: '2026-07-05T00:00:00.000Z' });
    const child1 = makeNormalTask('child-1', { isCompleted: true, completedAt: '2026-07-05T09:00:00.000Z' });
    const child2 = makeNormalTask('child-2', { isCompleted: false });
    const compound = makeCompoundTask('compound-1', { operator: OperatorType.AND });
    const boardTasks = [makeBoardTask(board.id, compound.id, 1, 1)];
    const taskMap = { [compound.id]: compound, [child1.id]: child1, [child2.id]: child2 };
    const childrenByCompound = {
      [compound.id]: [makeCompoundChild(compound.id, child1.id, 0), makeCompoundChild(compound.id, child2.id, 1)],
    };
    const eventsByTaskId = { [child1.id]: [completionEvent('e-1', child1.id, '2026-07-05T09:00:00.000Z')] };

    // AND with one incomplete child → not done.
    const notDone = buildBoardPreviewCells(board, boardTasks, taskMap, childrenByCompound, eventsByTaskId);
    expect(notDone.cells[4]).toEqual({ kind: 'task', completed: false });

    // Completing child2 (in-window) flips the AND compound to done.
    const child2Done = { ...child2, isCompleted: true };
    const taskMap2 = { ...taskMap, [child2.id]: child2Done };
    const eventsByTaskId2 = {
      ...eventsByTaskId,
      [child2.id]: [completionEvent('e-2', child2.id, '2026-07-05T10:00:00.000Z')],
    };
    const done = buildBoardPreviewCells(board, boardTasks, taskMap2, childrenByCompound, eventsByTaskId2);
    expect(done.cells[4]).toEqual({ kind: 'task', completed: true });
  });

  it('sealed board short-circuits to sealedCompletedCells, ignoring live event derivation entirely', () => {
    const board = makeBoard({
      boardSize: 3,
      startDate: '2026-07-01T00:00:00.000Z',
      sealedAt: '2026-07-02T06:00:00.000Z',
      // Only index 0 (row0,col0) is frozen as done.
      sealedCompletedCells: [0],
    });
    // task-a: lifetime cache says INCOMPLETE, but it's in the sealed set —
    // must still read as done (the snapshot wins).
    const taskA = makeNormalTask('task-a', { isCompleted: false });
    // task-b: lifetime cache says COMPLETE and there IS an in-window event,
    // but it's NOT in the sealed set — must still read as NOT done.
    const taskB = makeNormalTask('task-b', { isCompleted: true, completedAt: '2026-07-01T12:00:00.000Z' });
    const boardTasks = [makeBoardTask(board.id, taskA.id, 0, 0), makeBoardTask(board.id, taskB.id, 0, 1)];
    const taskMap = { [taskA.id]: taskA, [taskB.id]: taskB };
    const eventsByTaskId = { [taskB.id]: [completionEvent('e-1', taskB.id, '2026-07-01T12:00:00.000Z')] };

    const { cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, eventsByTaskId);

    expect(cells[0]).toEqual({ kind: 'task', completed: true });
    expect(cells[1]).toEqual({ kind: 'task', completed: false });
  });

  it('boardTasks belonging to a different board are ignored (defensive filter)', () => {
    const board = makeBoard({ id: 'board-1', boardSize: 3 });
    const task = makeNormalTask('t-1', { isCompleted: true });
    const foreignBoardTask = makeBoardTask('other-board', task.id, 0, 0);
    const taskMap = { [task.id]: task };

    const { cells } = buildBoardPreviewCells(board, [foreignBoardTask], taskMap, {}, {});

    expect(cells[0]).toEqual({ kind: 'empty' });
  });

  it('a placed BoardTask whose taskId is missing from taskMap renders empty (defensive)', () => {
    const board = makeBoard({ boardSize: 3 });
    const boardTasks = [makeBoardTask(board.id, 'missing-task', 0, 0)];
    const { cells } = buildBoardPreviewCells(board, boardTasks, {}, {}, {});
    expect(cells[0]).toEqual({ kind: 'empty' });
  });

  /**
   * Board-integrity PR-3 (issue #360, finding 2) — the mini-preview's own
   * copy of the web achievement-render gap: pre-fix, `taskToSquareState`
   * had no ACHIEVEMENT branch, so a placed achievement Task always fell
   * through to the plain-task branch (`task.isCompleted`, never written for
   * achievement tasks) and rendered permanently `completed: false` — same
   * bug as the live play grid, just a second hand-copy of it. Fixed by
   * running the shared kernel (`computeBoardGrid`) once per board and
   * threading its per-cell resolution through `taskToSquareState`.
   */
  describe('ACHIEVEMENT-typed tasks (board-integrity PR-3, issue #360)', () => {
    it('a specific-board watcher resolves completed when the referenced board is GREENLOG', () => {
      const board = makeBoard({ boardSize: 3, id: 'board-1' });
      const watchedBoard = makeBoard({
        id: 'watched-board',
        status: BoardStatus.COMPLETED,
      });
      const achievement = makeAchievementTask('ach-1', {
        achievementTrigger: AchievementTrigger.GREENLOG,
        referencedBoardId: watchedBoard.id,
      });
      const boardTasks = [makeBoardTask(board.id, achievement.id, 0, 0)];
      const taskMap = { [achievement.id]: achievement };

      const { cells } = buildBoardPreviewCells(
        board, boardTasks, taskMap, {}, {}, [board, watchedBoard],
      );

      expect(cells[0]).toEqual({ kind: 'task', completed: true });
    });

    it('a specific-board watcher resolves incomplete when the referenced board has not met the trigger', () => {
      const board = makeBoard({ boardSize: 3, id: 'board-1' });
      const watchedBoard = makeBoard({ id: 'watched-board', status: BoardStatus.ACTIVE });
      const achievement = makeAchievementTask('ach-1', {
        achievementTrigger: AchievementTrigger.GREENLOG,
        referencedBoardId: watchedBoard.id,
      });
      const boardTasks = [makeBoardTask(board.id, achievement.id, 0, 0)];
      const taskMap = { [achievement.id]: achievement };

      const { cells } = buildBoardPreviewCells(
        board, boardTasks, taskMap, {}, {}, [board, watchedBoard],
      );

      expect(cells[0]).toEqual({ kind: 'task', completed: false });
    });

    it('without allBoards (the default []), an achievement cell degrades to incomplete rather than crashing', () => {
      const board = makeBoard({ boardSize: 3, id: 'board-1' });
      const achievement = makeAchievementTask('ach-1', {
        achievementTrigger: AchievementTrigger.GREENLOG,
        referencedBoardId: 'some-other-board',
      });
      const boardTasks = [makeBoardTask(board.id, achievement.id, 0, 0)];
      const taskMap = { [achievement.id]: achievement };

      const { cells } = buildBoardPreviewCells(board, boardTasks, taskMap, {}, {});

      expect(cells[0]).toEqual({ kind: 'task', completed: false });
    });

    it('a recurring-template watcher resolves completed once enough in-window spawns meet the trigger', () => {
      const board = makeBoard({
        boardSize: 3,
        id: 'board-1',
        startDate: '2026-07-01T00:00:00.000Z',
        endDate: '2026-07-31T23:59:59.000Z',
      });
      const achievement = makeAchievementTask('ach-1', {
        achievementTrigger: AchievementTrigger.GREENLOG,
        referencedTemplateId: 'template-1',
        requiredCount: 2,
      });
      const spawn1 = makeBoard({
        id: 'spawn-1',
        status: BoardStatus.COMPLETED,
        spawnedFromTemplateId: 'template-1',
        startDate: '2026-07-05T00:00:00.000Z',
      });
      const spawn2 = makeBoard({
        id: 'spawn-2',
        status: BoardStatus.COMPLETED,
        spawnedFromTemplateId: 'template-1',
        startDate: '2026-07-12T00:00:00.000Z',
      });
      const boardTasks = [makeBoardTask(board.id, achievement.id, 0, 0)];
      const taskMap = { [achievement.id]: achievement };

      const { cells } = buildBoardPreviewCells(
        board, boardTasks, taskMap, {}, {}, [board, spawn1, spawn2],
      );

      expect(cells[0]).toEqual({ kind: 'task', completed: true });
    });
  });
});
