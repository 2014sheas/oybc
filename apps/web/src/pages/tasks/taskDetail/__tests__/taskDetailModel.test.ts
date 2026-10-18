import { afterEach, describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, OperatorType, TaskType, Timeframe, type Board, type BoardTask, type CompoundChild, type Task, type TaskEvent, type TaskPlacementRow } from '@oybc/shared';
import { db } from '../../../../db/internal';
import { loadTaskDetailPlacements } from '../../../../db/operations/taskDetailPlacements';
import { activityDot, activityFooter, activityWhen, buildBoardRows, heroKicker, heroTone, notDoneLabel, segmentOptions, subtasksHeading } from '../taskDetailModel';

const NOW = new Date('2026-10-15T12:00:00');
const iso = (d: Date): string => d.toISOString();
const task = (o: Partial<Task>): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', version: 1, isDeleted: false, ...o,
}) as Task;
const board = (o: Partial<Board>): Board => ({
  id: 'b1', userId: 'u', name: 'Week 42', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
  startDate: iso(new Date(NOW.getTime() - 2 * 864e5)), endDate: iso(new Date(NOW.getTime() + 5 * 864e5)),
  centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 1, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', version: 1, isDeleted: false, ...o,
}) as Board;
const placement = (o: Partial<BoardTask> = {}): BoardTask => ({
  id: 'p1', boardId: 'b1', taskId: 't', row: 0, col: 0, isCenter: false,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', version: 1, isDeleted: false, ...o,
});

describe('heroKicker', () => {
  it('derives each type\'s kicker from data', () => {
    expect(heroKicker(task({ type: TaskType.COUNTING }), null, 0)).toBe('COUNTING');
    expect(heroKicker(task({ type: TaskType.COUNTING, countKind: 'duration' }), null, 0)).toBe('COUNTING · DURATION');
    expect(heroKicker(task({ type: TaskType.COUNTING, countKind: 'continuous' }), null, 0)).toBe('COUNTING · CONTINUOUS');
    expect(heroKicker(task({ type: TaskType.COUNTING, isCounter: true }), null, 0)).toBe('COUNTING · LINKED COUNTER');
    expect(heroKicker(task({ type: TaskType.COUNTING, sharedCounterId: 'r' }), null, 0)).toBe('COUNTING · LINKED COUNTER');
    expect(heroKicker(task({}), 'Books', 0)).toBe('NORMAL · COUNTS TOWARD BOOKS');
    expect(heroKicker(task({}), null, 0)).toBe('NORMAL');
    expect(heroKicker(task({ type: TaskType.COMPOUND, operator: OperatorType.AND }), null, 3)).toBe('COMPOUND · ALL OF 3');
    expect(heroKicker(task({ type: TaskType.COMPOUND, operator: OperatorType.OR }), null, 3)).toBe('COMPOUND · ANY OF 3');
    expect(heroKicker(task({ type: TaskType.COMPOUND, operator: OperatorType.M_OF_N, threshold: 2 }), null, 3)).toBe('COMPOUND · 2 OF 3');
    expect(heroKicker(task({ type: TaskType.ACHIEVEMENT, achievementTrigger: 'bingo' as never }), null, 0)).toBe('ACHIEVEMENT · FIRST BINGO');
    expect(heroKicker(task({ type: TaskType.ACHIEVEMENT }), null, 0)).toBe('ACHIEVEMENT · GREENLOG');
  });
  it('picks the band tone per type', () => {
    expect(heroTone(task({ type: TaskType.COUNTING }))).toBe('counting');
    expect(heroTone(task({ type: TaskType.COMPOUND }))).toBe('compound');
    expect(heroTone(task({ type: TaskType.ACHIEVEMENT }))).toBe('achievement');
    expect(heroTone(task({}))).toBe('normal');
  });
});

describe('segments + activity dots', () => {
  it('Boards carries its placement count', () => {
    expect(segmentOptions(0).map((o) => o.label)).toEqual(['All', 'Boards', 'Links', 'Activity']);
    expect(segmentOptions(2)[1]).toEqual({ value: 'boards', label: 'Boards · 2' });
  });
  it('dot colours per kind', () => {
    expect(activityDot('logged')).toBe('var(--riso-blue)');
    expect(activityDot('removed')).toBe('var(--riso-blue)');
    expect(activityDot('completed')).toBe('var(--riso-green)');
    expect(activityDot('placed')).toBe('var(--riso-gold)');
    expect(activityDot('missed')).toBe('var(--riso-red)');
    expect(activityDot('created')).toBe('var(--riso-paper)');
  });
  it('short dates; unparseable reads empty', () => {
    expect(activityWhen('2026-10-12T09:00:00')).toBe('Oct 12');
    expect(activityWhen('nope')).toBe('');
  });
});

/** A kernel row (`taskPlacementRows`) for board `boardId`. */
const kRow = (o: Partial<TaskPlacementRow> = {}): TaskPlacementRow => ({
  boardId: 'b1', boardTaskId: 'p1', memberTaskId: 't', viaCompoundId: null, done: false,
  count: null, goal: null, childrenDone: null, childrenTotal: null, ...o,
});

describe('buildBoardRows', () => {
  const counting = task({ type: TaskType.COUNTING, maxCount: 20, unit: 'pages', action: 'Read' });
  const input = (rows: TaskPlacementRow[], boards: Board[]) => ({ rows, boards, taskById: { t: counting }, now: NOW });

  it('formats the windowed count; active rows carry window · ends · days left', () => {
    const [row] = buildBoardRows(input([kRow({ count: 12, goal: 20 })], [board({})]));
    expect(row.value).toBe('12/20');
    expect(row.done).toBe(false);
    expect(row.fraction).toBeCloseTo(0.6);
    expect(row.active).toBe(true);
    expect(row.caption).toMatch(/ends \w{3} · 5 days left/);
    expect(row.missed).toBe(false);
  });

  it('an overshoot stays visible and the ring is full', () => {
    const [row] = buildBoardRows(input([kRow({ count: 25, goal: 20, done: true })], [board({})]));
    expect(row.value).toBe('25/20');
    expect(row.done).toBe(true);
    expect(row.fraction).toBe(1);
  });

  it('an ended, incomplete board is past and missed; a draft is past and never missed', () => {
    const ended = board({ id: 'b2', endDate: iso(new Date(NOW.getTime() - 864e5)) });
    const draft = board({ id: 'b3', status: BoardStatus.DRAFT });
    const rows = buildBoardRows(input(
      [kRow({ boardId: 'b2', count: 0, goal: 20 }), kRow({ boardId: 'b3', boardTaskId: 'p3', count: 0, goal: 20 })],
      [ended, draft],
    ));
    expect(rows[0]).toMatchObject({ active: false, missed: true });
    expect(rows[0].caption).toMatch(/expired$/);
    expect(rows[1]).toMatchObject({ draft: true, active: false, missed: false, caption: 'Draft' });
  });

  it('a core board gets the Core badge; a board with no kernel row is skipped', () => {
    const rows = buildBoardRows(input([kRow({ count: 0, goal: 20 })], [board({ isCore: true }), board({ id: 'b9' })]));
    expect(rows).toHaveLength(1);
    expect(rows[0].badge).toBe('Core · weekly');
  });

  it('a closed board whose window is over, not done, is missed — same rule as iOS', () => {
    const closed = board({ endDate: iso(new Date(NOW.getTime() - 864e5)), sealedAt: iso(new Date(NOW.getTime() - 3600e3)), sealedCompletedCells: [] });
    const [row] = buildBoardRows(input([kRow({ count: 3, goal: 20 })], [closed]));
    expect(row).toMatchObject({ active: false, missed: true });
    expect(row.caption).toMatch(/closed$/);
  });

  it('a goal-less counter shows its count alone', () => {
    const noGoal = task({ type: TaskType.COUNTING, maxCount: undefined });
    const [row] = buildBoardRows({ rows: [kRow({ count: 3, goal: null })], boards: [board({})], taskById: { t: noGoal }, now: NOW });
    expect(row.value).toBe('3');
  });

  it('a compound member reads n/N; a goal-less counting member is never missed', () => {
    const compound = task({ id: 'c', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const [c] = buildBoardRows({ rows: [kRow({ memberTaskId: 'c', childrenDone: 1, childrenTotal: 3 })], boards: [board({})], taskById: { c: compound }, now: NOW });
    expect(c.value).toBe('1/3');
    expect(c.fraction).toBeCloseTo(1 / 3);
    const noGoal = task({ type: TaskType.COUNTING, maxCount: undefined });
    const ended = board({ endDate: iso(new Date(NOW.getTime() - 864e5)) });
    const [n] = buildBoardRows({ rows: [kRow({ count: 0, goal: null })], boards: [ended], taskById: { t: noGoal }, now: NOW });
    expect(n.missed).toBe(false);
  });
});

describe('activityFooter (#384)', () => {
  it('a Simple task carries its completion count; every other type only the update time', () => {
    expect(activityFooter(TaskType.NORMAL, 3, '2 days ago')).toBe('Completed 3× all-time · updated 2 days ago');
    expect(activityFooter(TaskType.NORMAL, 0, null)).toBe('Completed 0× all-time');
    for (const type of [TaskType.COUNTING, TaskType.COMPOUND, TaskType.ACHIEVEMENT]) {
      expect(activityFooter(type, 0, '2 days ago')).toBe('Updated 2 days ago');
      expect(activityFooter(type, 4, null)).toBe('');
    }
  });
});

describe('notDoneLabel + subtasksHeading', () => {
  it('names the anchor window', () => {
    expect(notDoneLabel('daily')).toBe('NOT DONE TODAY');
    expect(notDoneLabel('weekly')).toBe('NOT DONE THIS WEEK');
    expect(notDoneLabel('monthly')).toBe('NOT DONE THIS MONTH');
    expect(notDoneLabel('yearly')).toBe('NOT DONE THIS YEAR');
    expect(notDoneLabel('custom')).toBe('NOT DONE');
    expect(notDoneLabel(undefined)).toBe('NOT DONE');
  });
  it('writes the rule from the operator', () => {
    expect(subtasksHeading(task({ type: TaskType.COMPOUND, operator: OperatorType.AND }), 3)).toBe('Sub-tasks (3) · all of 3');
    expect(subtasksHeading(task({ type: TaskType.COMPOUND, operator: OperatorType.OR }), 3)).toBe('Sub-tasks (3) · any of 3');
    expect(subtasksHeading(task({ type: TaskType.COMPOUND, operator: OperatorType.M_OF_N, threshold: 2 }), 3)).toBe('Sub-tasks (3) · at least 2 of 3');
  });
});

describe('loadTaskDetailPlacements (PR 5 — placement resolution)', () => {
  afterEach(async () => {
    await Promise.all([db.boardTasks.clear(), db.boards.clear(), db.tasks.clear(), db.compoundChildren.clear(), db.taskEvents.clear()]);
  });
  const link = (compoundTaskId: string, childTaskId: string): CompoundChild => ({
    id: `l-${compoundTaskId}-${childTaskId}`, userId: 'u', compoundTaskId, childTaskId, childIndex: 0,
    createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', version: 1, isDeleted: false,
  }) as CompoundChild;

  it('a sub-task placed only through its compound gets that board, scored as the sub-task', async () => {
    await db.tasks.bulkAdd([task({ id: 's' }), task({ id: 'P', type: TaskType.COMPOUND, operator: OperatorType.AND })]);
    await db.compoundChildren.add(link('P', 's'));
    await db.boards.add(board({}));
    await db.boardTasks.bulkAdd([placement({ taskId: 'P' }), placement({ id: 'p9', taskId: 'other' })]);
    const got = await loadTaskDetailPlacements('s');
    expect(got.ownPlacements).toEqual([]);
    expect(got.boards.map((b) => b.id)).toEqual(['b1']);
    expect(got.rows).toEqual([expect.objectContaining({ boardId: 'b1', memberTaskId: 's', viaCompoundId: 'P', done: false })]);
  });

  it('a direct Normal / Counting sub-task anchors on its compound\'s square; a sub-compound or a deeper one does not', async () => {
    await db.tasks.bulkAdd([
      task({ id: 'P', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task({ id: 'n' }),
      task({ id: 'Q', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task({ id: 'm' }),
    ]);
    await db.compoundChildren.bulkAdd([link('P', 'n'), link('P', 'Q'), link('Q', 'm')]);
    await db.boards.add(board({}));
    await db.boardTasks.add(placement({ taskId: 'P' }));
    const candidates = async (id: string) => (await loadTaskDetailPlacements(id)).anchorCandidates.map((c) => [c.placement.id, c.childTaskId, c.rank]);
    expect(await candidates('n')).toEqual([['p1', 'n', 2]]);
    expect(await candidates('Q')).toEqual([]);
    expect(await candidates('m')).toEqual([]);
  });

  const done = (taskId: string): TaskEvent => ({
    id: `done-${taskId}`, taskId, userId: 'u', kind: 'completion', occurredAt: iso(new Date(NOW.getTime() - 3600e3)),
    createdAt: iso(NOW), updatedAt: iso(NOW), version: 1, isDeleted: false,
  }) as TaskEvent;

  it('a compound loads its nested sub-tree: a nested sub-compound counts its own sub-tasks', async () => {
    await db.tasks.bulkAdd([
      task({ id: 'P', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task({ id: 'n' }),
      task({ id: 'Q', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task({ id: 'm' }),
    ]);
    await db.compoundChildren.bulkAdd([link('P', 'n'), link('P', 'Q'), link('Q', 'm')]);
    await db.boards.add(board({}));
    await db.boardTasks.add(placement({ taskId: 'P' }));
    await db.taskEvents.bulkAdd([done('n'), done('m')]);
    const got = await loadTaskDetailPlacements('P');
    expect(got.rows).toEqual([expect.objectContaining({ memberTaskId: 'P', done: true, childrenDone: 2, childrenTotal: 2 })]);
  });

  it('an achievement reads its watched board (a bingo there completes its cell)', async () => {
    await db.tasks.add(task({ id: 'a', type: TaskType.ACHIEVEMENT, achievementTrigger: 'bingo' as never, referencedBoardId: 'W' }));
    await db.boards.bulkAdd([board({}), board({ id: 'W', linesCompleted: 1 })]);
    await db.boardTasks.add(placement({ taskId: 'a' }));
    const got = await loadTaskDetailPlacements('a');
    expect(got.rows).toEqual([expect.objectContaining({ boardId: 'b1', memberTaskId: 'a', done: true })]);
  });

  it('a counter root reaches its linked row\'s board; tombstoned placements and boards drop out', async () => {
    await db.tasks.bulkAdd([
      task({ id: 'r', type: TaskType.COUNTING, isCounter: true }),
      task({ id: 'l', type: TaskType.COUNTING, maxCount: 5, sharedCounterId: 'r', baseline: 0 }),
    ]);
    await db.boards.bulkAdd([board({}), board({ id: 'bx', isDeleted: true })]);
    await db.boardTasks.bulkAdd([
      placement({ taskId: 'l' }),
      placement({ id: 'p2', boardId: 'bx', taskId: 'l' }),
      placement({ id: 'p3', taskId: 'r', isDeleted: true }),
    ]);
    const got = await loadTaskDetailPlacements('r');
    expect(got.ownPlacements).toEqual([]);
    // The root's hero may anchor on its linked row's square (a log there writes the root).
    expect(got.anchorCandidates.map((c) => [c.placement.id, c.childTaskId, c.rank])).toEqual([['p1', null, 1], ['p2', null, 1]]);
    expect(got.rows.map((r) => [r.boardId, r.memberTaskId, r.goal])).toEqual([['b1', 'l', 5]]);
  });
});
