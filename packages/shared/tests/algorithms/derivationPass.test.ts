import {
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
} from '../../src/algorithms/derivationPass';
import { CenterSquareType, OperatorType, TaskType, BoardStatus, Timeframe } from '../../src/constants/enums';
import type { Task, CompoundChild, BoardTask, Board } from '../../src';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function compoundTask(id: string, operator: OperatorType, overrides: Partial<Task> = {}): Task {
  return task(id, { type: TaskType.COMPOUND, operator, ...overrides });
}

function child(
  parentId: string,
  childId: string,
  idx: number,
  overrides: Partial<CompoundChild> = {},
): CompoundChild {
  return {
    id: `${parentId}-${childId}-${idx}`,
    compoundTaskId: parentId,
    childTaskId: childId,
    childIndex: idx,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function boardTask(
  boardId: string,
  taskId: string,
  row: number,
  col: number,
  overrides: Partial<BoardTask> = {},
): BoardTask {
  return {
    id: `${boardId}-${taskId}`,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    ...overrides,
  };
}

function board(id: string, overrides: Partial<Board> = {}): Board {
  return {
    id,
    userId: 'u',
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: '2026-04-01T00:00:00.000Z',
    endDate: '2026-04-30T23:59:59.000Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── findTransitiveParentCompounds ────────────────────────────────────────────

describe('findTransitiveParentCompounds', () => {
  it('returns empty set when the changed task is not a child of any compound', () => {
    const children: CompoundChild[] = [
      child('compA', 'otherTask', 0),
    ];
    const result = findTransitiveParentCompounds('changedTask', children);
    expect(result.size).toBe(0);
  });

  it('returns the immediate parent when the changed task is a child of one compound', () => {
    const children: CompoundChild[] = [
      child('compA', 'changedTask', 0),
      child('compA', 'otherTask', 1),
    ];
    const result = findTransitiveParentCompounds('changedTask', children);
    expect(result).toEqual(new Set(['compA']));
  });

  it('returns immediate parent + grandparent when nested (A contains B contains changedTask)', () => {
    // compB directly contains changedTask; compA contains compB
    const children: CompoundChild[] = [
      child('compB', 'changedTask', 0),
      child('compA', 'compB', 0),
    ];
    const result = findTransitiveParentCompounds('changedTask', children);
    expect(result).toEqual(new Set(['compB', 'compA']));
  });

  it('filters soft-deleted CompoundChild links (deleted link does not contribute its parent)', () => {
    const children: CompoundChild[] = [
      child('compA', 'changedTask', 0, { isDeleted: true }),
      child('compB', 'changedTask', 0),
    ];
    const result = findTransitiveParentCompounds('changedTask', children);
    // compA's link is deleted → not included; compB's link is active → included
    expect(result).toEqual(new Set(['compB']));
    expect(result.has('compA')).toBe(false);
  });

  it('handles a cycle (A→B→A) without infinite loop and includes both ids', () => {
    // changedTask is child of compA; compA is child of compB; compB is child of compA (cycle)
    const children: CompoundChild[] = [
      child('compA', 'changedTask', 0),
      child('compB', 'compA', 0),
      child('compA', 'compB', 1), // cycle: compA also contains compB
    ];
    const result = findTransitiveParentCompounds('changedTask', children);
    // Should terminate; both compA and compB should be included
    expect(result.has('compA')).toBe(true);
    expect(result.has('compB')).toBe(true);
  });
});

// ─── findAffectedBoardIds ─────────────────────────────────────────────────────

describe('findAffectedBoardIds', () => {
  it('returns the board placing the changed task directly', () => {
    const boardTasks: BoardTask[] = [
      boardTask('boardA', 'changedTask', 0, 0),
    ];
    const result = findAffectedBoardIds('changedTask', new Set(), boardTasks);
    expect(result).toEqual(new Set(['boardA']));
  });

  it('returns the board placing a parent compound (passed via parentCompounds)', () => {
    const boardTasks: BoardTask[] = [
      boardTask('boardA', 'compA', 0, 0),
    ];
    const result = findAffectedBoardIds('changedTask', new Set(['compA']), boardTasks);
    expect(result).toEqual(new Set(['boardA']));
  });

  it('returns the union when the changed task is on boardA and a parent compound is on boardB', () => {
    const boardTasks: BoardTask[] = [
      boardTask('boardA', 'changedTask', 0, 0),
      boardTask('boardB', 'compA', 1, 1),
    ];
    const result = findAffectedBoardIds('changedTask', new Set(['compA']), boardTasks);
    expect(result).toEqual(new Set(['boardA', 'boardB']));
  });

  it('returns empty set when no boards reference any of the relevant ids', () => {
    const boardTasks: BoardTask[] = [
      boardTask('boardA', 'unrelatedTask', 0, 0),
    ];
    const result = findAffectedBoardIds('changedTask', new Set(['compA']), boardTasks);
    expect(result.size).toBe(0);
  });

  it('deduplicates: same board placing both the changed task and a parent compound appears only once', () => {
    const boardTasks: BoardTask[] = [
      boardTask('boardA', 'changedTask', 0, 0),
      boardTask('boardA', 'compA', 1, 1),
    ];
    const result = findAffectedBoardIds('changedTask', new Set(['compA']), boardTasks);
    expect(result).toEqual(new Set(['boardA']));
    expect(result.size).toBe(1);
  });
});

// ─── computeBoardStatsUpdate ──────────────────────────────────────────────────

describe('computeBoardStatsUpdate', () => {
  it('builds a grid where primitive tasks complete based on Task.isCompleted', () => {
    // 3x3 board: task at (0,0) is complete, (0,1) is not
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const tDone = task('t1', { isCompleted: true });
    const tPending = task('t2', { isCompleted: false });
    const bts = [boardTask('b1', 't1', 0, 0), boardTask('b1', 't2', 0, 1)];
    const taskById = { t1: tDone, t2: tPending };

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.completedTasks).toBe(1);
    // row_0 not complete (t2 not done), so no bingos
    expect(result.linesCompleted).toBe(0);
    expect(result.completedLineIds).toEqual([]);
  });

  it('compound BoardTasks compute via evaluateCompound — compound at (1,1) with all children complete increments completedTasks', () => {
    // 3x3 board; compound at (1,1); compound is AND of [child1, child2]; both complete
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const comp = compoundTask('comp', OperatorType.AND);
    const child1 = task('c1', { isCompleted: true });
    const child2 = task('c2', { isCompleted: true });
    const bts = [boardTask('b1', 'comp', 1, 1)];
    const taskById = { comp, c1: child1, c2: child2 };
    const childrenByCompound = {
      comp: [child('comp', 'c1', 0), child('comp', 'c2', 1)],
    };

    const result = computeBoardStatsUpdate(b, bts, childrenByCompound, taskById);
    expect(result.completedTasks).toBe(1);
  });

  it('compound at (1,1) with one incomplete child is NOT counted as completed', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const comp = compoundTask('comp', OperatorType.AND);
    const child1 = task('c1', { isCompleted: true });
    const child2 = task('c2', { isCompleted: false });
    const bts = [boardTask('b1', 'comp', 1, 1)];
    const taskById = { comp, c1: child1, c2: child2 };
    const childrenByCompound = {
      comp: [child('comp', 'c1', 0), child('comp', 'c2', 1)],
    };

    const result = computeBoardStatsUpdate(b, bts, childrenByCompound, taskById);
    expect(result.completedTasks).toBe(0);
  });

  it('linesCompleted matches detectBingos output for a hand-crafted complete row', () => {
    // 3x3 board with row 0 fully complete (tasks at col 0, 1, 2 all done)
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const t0 = task('t0', { isCompleted: true });
    const t1 = task('t1', { isCompleted: true });
    const t2 = task('t2', { isCompleted: true });
    const bts = [
      boardTask('b1', 't0', 0, 0),
      boardTask('b1', 't1', 0, 1),
      boardTask('b1', 't2', 0, 2),
    ];
    const taskById = { t0, t1, t2 };

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.linesCompleted).toBe(1);
    expect(result.completedLineIds).toContain('row_0');
  });

  it('newBingos contains newly detected line when previous completedLineIds was empty', () => {
    // pre-state: no bingos; post-state: row_0 completed
    const b = board('b1', { boardSize: 3, completedLineIds: [], centerSquareType: CenterSquareType.NONE });
    const t0 = task('t0', { isCompleted: true });
    const t1 = task('t1', { isCompleted: true });
    const t2 = task('t2', { isCompleted: true });
    const bts = [
      boardTask('b1', 't0', 0, 0),
      boardTask('b1', 't1', 0, 1),
      boardTask('b1', 't2', 0, 2),
    ];
    const taskById = { t0, t1, t2 };

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.newBingos).toContain('row_0');
    expect(result.lostBingos).toEqual([]);
  });

  it('lostBingos contains line when it was previously completed but now is not', () => {
    // pre-state: row_0 was complete; post-state: no tasks done → row_0 lost
    const b = board('b1', { boardSize: 3, completedLineIds: ['row_0'], centerSquareType: CenterSquareType.NONE });
    const t0 = task('t0', { isCompleted: false });
    const t1 = task('t1', { isCompleted: false });
    const t2 = task('t2', { isCompleted: false });
    const bts = [
      boardTask('b1', 't0', 0, 0),
      boardTask('b1', 't1', 0, 1),
      boardTask('b1', 't2', 0, 2),
    ];
    const taskById = { t0, t1, t2 };

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.lostBingos).toContain('row_0');
    expect(result.newBingos).toEqual([]);
  });

  it('center auto-fill: 3x3 FREE board with no task at (1,1) treats center as completed', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.FREE });
    // No BoardTask at (1,1)
    const bts: BoardTask[] = [];
    const result = computeBoardStatsUpdate(b, bts, {}, {});
    // Center (index 4 in 3x3) should be auto-filled
    expect(result.completedTasks).toBe(1);
  });

  it('center auto-fill: 3x3 CUSTOM_FREE board with no task at (1,1) treats center as completed', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.CUSTOM_FREE });
    const bts: BoardTask[] = [];
    const result = computeBoardStatsUpdate(b, bts, {}, {});
    expect(result.completedTasks).toBe(1);
  });

  it('center NOT auto-filled when centerSquareType=CHOSEN on odd board', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.CHOSEN });
    const bts: BoardTask[] = [];
    const result = computeBoardStatsUpdate(b, bts, {}, {});
    expect(result.completedTasks).toBe(0);
  });

  it('center NOT auto-filled when centerSquareType=NONE on odd board', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const bts: BoardTask[] = [];
    const result = computeBoardStatsUpdate(b, bts, {}, {});
    expect(result.completedTasks).toBe(0);
  });

  it('center auto-fill triggers bingo detection correctly — FREE 3x3 with full center column triggers diag and col bingos', () => {
    // 3x3 with FREE center; fill col 1 (row 0, row 1 via free-center, row 2) and main diagonal
    // col 1: (0,1) and (2,1) done + (1,1) auto-filled → col_1 complete
    // main diag: (0,0), (1,1) free, (2,2) → need (0,0) and (2,2) done
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.FREE });
    const t01 = task('t01', { isCompleted: true });  // (0,1)
    const t21 = task('t21', { isCompleted: true });  // (2,1)
    const t00 = task('t00', { isCompleted: true });  // (0,0)
    const t22 = task('t22', { isCompleted: true });  // (2,2)
    const bts = [
      boardTask('b1', 't01', 0, 1),
      boardTask('b1', 't21', 2, 1),
      boardTask('b1', 't00', 0, 0),
      boardTask('b1', 't22', 2, 2),
    ];
    const taskById = { t01, t21, t00, t22 };
    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    // auto-filled center counts + 4 explicit tasks
    expect(result.completedTasks).toBe(5);
    expect(result.completedLineIds).toContain('col_1');
    expect(result.completedLineIds).toContain('diag_main');
  });

  it('soft-deleted Tasks contribute nothing to the grid', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const deletedTask = task('t1', { isCompleted: true, isDeleted: true });
    const bts = [boardTask('b1', 't1', 0, 0)];
    const taskById = { t1: deletedTask };

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.completedTasks).toBe(0);
  });

  it('BoardTask referencing missing taskId contributes nothing to the grid', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const bts = [boardTask('b1', 'ghost', 0, 0)];
    const taskById = {};

    const result = computeBoardStatsUpdate(b, bts, {}, taskById);
    expect(result.completedTasks).toBe(0);
  });

  it('boardId in result matches the input board', () => {
    const b = board('myBoard', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const result = computeBoardStatsUpdate(b, [], {}, {});
    expect(result.boardId).toBe('myBoard');
  });

  it('skips out-of-bounds row/col defensively', () => {
    // BoardTask with row=99 exceeds boardSize=3 — idx will be out of range and must be skipped
    const b = board('myBoard', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const t = task('t1', { isCompleted: true });
    const stale = boardTask('myBoard', 't1', 99, 0); // row 99 is out of bounds for a 3x3 board
    const result = computeBoardStatsUpdate(b, [stale], {}, { t1: t });
    expect(result.completedTasks).toBe(0);
    expect(result.completedLineIds).toEqual([]);
  });

  it('handles board.completedLineIds === undefined (defensive)', () => {
    // Board row from legacy data may have completedLineIds absent
    const b = board('myBoard', { boardSize: 3, centerSquareType: CenterSquareType.NONE, completedLineIds: undefined });
    // Empty task list → no bingos, so diff produces no new or lost lines
    const result = computeBoardStatsUpdate(b, [], {}, {});
    expect(result.newBingos).toEqual([]);
    expect(result.lostBingos).toEqual([]);
  });

  // ─── Achievement-typed Task completion (Phase 6.3) ─────────────────────────
  //
  // Achievement Tasks carry the cross-board reference (`referencedBoardId`
  // XOR `referencedTemplateId`); BoardTask is a pure placement record. The
  // pre-refactor "aggregate mode" (achievementCount / achievementProgress)
  // was dropped — achievement Tasks must reference SOMETHING. A reference-less
  // achievement Task degrades safely (incomplete) but should never reach the
  // DB because Zod rejects it.

  it('achievement Task with no reference set → cell incomplete (degrades safely)', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ach = task('ach1', { type: TaskType.ACHIEVEMENT });
    const bt = boardTask('b1', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(b, [bt], {}, { ach1: ach });
    expect(result.completedTasks).toBe(0);
  });

  it('achievement Task ignores its own isCompleted — Task with isCompleted=true and no ref still incomplete', () => {
    const b = board('b1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    // Even if a stale write set isCompleted=true on the achievement Task
    // row, derivation cares about the *reference*, not the field.
    const ach = task('ach1', { type: TaskType.ACHIEVEMENT, isCompleted: true });
    const bt = boardTask('b1', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(b, [bt], {}, { ach1: ach });
    expect(result.completedTasks).toBe(0);
  });
});

// ─── Phase 6.3: specific-board + recurring-template achievement tasks ──────
//
// Achievement-typed Tasks carry the cross-board reference fields. BoardTask
// is a pure placement record — the same achievement Task on three boards is
// just three placement rows, each evaluated against the same Task definition.

function achievementTask(
  id: string,
  refs: { referencedBoardId?: string; referencedTemplateId?: string },
): Task {
  return task(id, { type: TaskType.ACHIEVEMENT, ...refs });
}

describe('computeBoardStatsUpdate — Phase 6.3 specific-board mode', () => {
  it('referencedBoardId pointing at COMPLETED non-deleted board → cell completes', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ref = board('ref', { status: BoardStatus.COMPLETED });
    const ach = achievementTask('ach1', { referencedBoardId: 'ref' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, ref]);
    expect(result.completedTasks).toBe(1);
  });

  it('referencedBoardId pointing at ACTIVE board → cell incomplete', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ref = board('ref', { status: BoardStatus.ACTIVE });
    const ach = achievementTask('ach1', { referencedBoardId: 'ref' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, ref]);
    expect(result.completedTasks).toBe(0);
  });

  it('referencedBoardId pointing at soft-deleted board → cell incomplete (no crash)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ref = board('ref', { status: BoardStatus.COMPLETED, isDeleted: true });
    const ach = achievementTask('ach1', { referencedBoardId: 'ref' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, ref]);
    expect(result.completedTasks).toBe(0);
  });

  it('referencedBoardId pointing at a board not in allBoards → cell incomplete', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ach = achievementTask('ach1', { referencedBoardId: 'missing' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent]);
    expect(result.completedTasks).toBe(0);
  });
});

describe('computeBoardStatsUpdate — Phase 6.3 recurring-template mode', () => {
  // Parent monthly window: April 1 – April 30, 2026 (the default `board()` shape).
  // Spawns we craft below all use the parent's `spawnedFromTemplateId` lookup.

  it('all in-window spawns COMPLETED → cell completes', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-08T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const s2 = board('s2', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-15T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1, s2]);
    expect(result.completedTasks).toBe(1);
  });

  it('one in-window spawn ACTIVE → cell incomplete (ALL must complete)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-08T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const s2 = board('s2', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-15T00:00:00.000Z',
      status: BoardStatus.ACTIVE,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1, s2]);
    expect(result.completedTasks).toBe(0);
  });

  it('empty in-window spawn set → cell incomplete (NOT vacuously complete)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent]);
    expect(result.completedTasks).toBe(0);
  });

  it('out-of-window spawn ignored — only spawn is BEFORE parent.startDate → cell incomplete', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-03-15T00:00:00.000Z', // March, before parent April window
      status: BoardStatus.COMPLETED,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1]);
    expect(result.completedTasks).toBe(0);
  });

  it('partial-delete: 4 spawns, 3 COMPLETED + 1 pending soft-deleted → cell completes (only non-deleted in-window count)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-08T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const s2 = board('s2', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-15T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const s3 = board('s3', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-22T00:00:00.000Z',
      status: BoardStatus.COMPLETED,
    });
    const s4 = board('s4', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-29T00:00:00.000Z',
      status: BoardStatus.ACTIVE,
      isDeleted: true,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1, s2, s3, s4]);
    expect(result.completedTasks).toBe(1);
  });

  it('boundary: spawn whose startDate === parent.startDate counts (inclusive)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-01T00:00:00.000Z', // exactly parent.startDate
      status: BoardStatus.COMPLETED,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1]);
    expect(result.completedTasks).toBe(1);
  });

  it('boundary: spawn whose startDate === parent.endDate counts (inclusive)', () => {
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const s1 = board('s1', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-30T23:59:59.000Z', // exactly parent.endDate
      status: BoardStatus.COMPLETED,
    });
    const ach = achievementTask('ach1', { referencedTemplateId: 't1' });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, s1]);
    expect(result.completedTasks).toBe(1);
  });
});

describe('computeBoardStatsUpdate — Phase 6.3 bad-data precedence', () => {
  it('both referencedBoardId AND referencedTemplateId set on Task → referencedBoardId wins', () => {
    // Zod refinement rejects rows with both set, but a malicious remote
    // payload or older client could still produce one. Derivation must
    // be deterministic: the more-specific reference wins.
    const parent = board('parent', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    const ref = board('ref', { status: BoardStatus.COMPLETED });
    // Template branch would say "incomplete" here (no spawns at all),
    // but referencedBoardId branch wins → COMPLETED → cell completes.
    const ach = achievementTask('ach1', {
      referencedBoardId: 'ref',
      referencedTemplateId: 't1', // would lose to referencedBoardId precedence
    });
    const bt = boardTask('parent', 'ach1', 0, 0);
    const result = computeBoardStatsUpdate(parent, [bt], {}, { ach1: ach }, [parent, ref]);
    expect(result.completedTasks).toBe(1);
  });
});
