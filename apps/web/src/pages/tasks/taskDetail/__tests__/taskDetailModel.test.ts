import { afterEach, describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, OperatorType, TaskType, Timeframe, type Board, type BoardTask, type Task, type TaskEvent } from '@oybc/shared';
import { db } from '../../../../db/internal';
import { resolveTaskPlacements } from '../../../../hooks/useTaskDetail';
import { activityDot, activityWhen, buildBoardRows, heroKicker, heroTone, notDoneLabel, segmentOptions, subtasksHeading } from '../taskDetailModel';

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
const inc = (taskId: string, delta: number, at: Date): TaskEvent => ({
  id: `e${taskId}${delta}${at.getTime()}`, taskId, userId: 'u', kind: 'increment', delta, occurredAt: iso(at),
  createdAt: iso(at), updatedAt: iso(at), version: 1, isDeleted: false,
}) as TaskEvent;

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

describe('buildBoardRows', () => {
  const counting = task({ type: TaskType.COUNTING, maxCount: 20, unit: 'pages', action: 'Read' });
  const input = (events: TaskEvent[], boards: Board[]) => ({
    task: counting, boards, events, taskMap: { t: counting }, childrenByCompound: {}, placements: [placement()], now: NOW,
  });

  it('reads the windowed count per board; active rows carry window · ends · days left', () => {
    const [row] = buildBoardRows(input([inc('t', 12, new Date(NOW.getTime() - 864e5))], [board({})]));
    expect(row.value).toBe('12/20');
    expect(row.done).toBe(false);
    expect(row.fraction).toBeCloseTo(0.6);
    expect(row.active).toBe(true);
    expect(row.caption).toMatch(/ends \w{3} · 5 days left/);
    expect(row.missed).toBe(false);
  });

  it('an overshoot stays visible and the ring is full', () => {
    const [row] = buildBoardRows(input([inc('t', 25, new Date(NOW.getTime() - 864e5))], [board({})]));
    expect(row.value).toBe('25/20');
    expect(row.done).toBe(true);
    expect(row.fraction).toBe(1);
  });

  it('an ended, incomplete board is past and missed; a draft is past and never missed', () => {
    const ended = board({ id: 'b2', endDate: iso(new Date(NOW.getTime() - 864e5)) });
    const draft = board({ id: 'b3', status: BoardStatus.DRAFT });
    const rows = buildBoardRows({ ...input([], [ended, draft]), placements: [placement({ boardId: 'b2' }), placement({ id: 'p3', boardId: 'b3' })] });
    expect(rows[0]).toMatchObject({ active: false, missed: true });
    expect(rows[0].caption).toMatch(/expired$/);
    expect(rows[1]).toMatchObject({ draft: true, active: false, missed: false, caption: 'Draft' });
  });

  it('a core board gets the Core badge', () => {
    const [row] = buildBoardRows(input([], [board({ isCore: true })]));
    expect(row.badge).toBe('Core · weekly');
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

describe('buildBoardRows — per-placement reads', () => {
  it('reads the placement-adjusted goal (targetOverride) and the seal bound', () => {
    const counting = task({ type: TaskType.COUNTING, maxCount: 20, unit: 'pages' });
    const events = [inc('t', 12, new Date(NOW.getTime() - 864e5))];
    const [row] = buildBoardRows({
      task: counting, boards: [board({})], events, taskMap: { t: counting }, childrenByCompound: {},
      placements: [placement({ targetOverride: 10, targetKind: 'discrete' } as Partial<BoardTask>)], now: NOW,
    });
    expect(row.value).toBe('12/10');
    // A seal before the log hides it (the seal bound reaches the resolvers).
    const sealed = board({ sealedAt: iso(new Date(NOW.getTime() - 2 * 864e5 + 1000)), sealedCompletedCells: [] });
    const [closed] = buildBoardRows({ task: counting, boards: [sealed], events, taskMap: { t: counting }, childrenByCompound: {}, placements: [placement()], now: NOW });
    expect(closed.done).toBe(false);
  });
  it('a counting task without a goal is never "missed"', () => {
    const noGoal = task({ type: TaskType.COUNTING, maxCount: undefined });
    const ended = board({ endDate: iso(new Date(NOW.getTime() - 864e5)) });
    const [row] = buildBoardRows({ task: noGoal, boards: [ended], events: [], taskMap: { t: noGoal }, childrenByCompound: {}, placements: [placement()], now: NOW });
    expect(row.missed).toBe(false);
  });
});

describe('resolveTaskPlacements (the PR 5 seam)', () => {
  afterEach(async () => { await db.boardTasks.clear(); });
  it('returns the live placements of the task id', async () => {
    await db.boardTasks.bulkAdd([placement(), placement({ id: 'p2', taskId: 'other' }), placement({ id: 'p3', isDeleted: true })]);
    const got = await resolveTaskPlacements('t');
    expect(got.map((p) => p.id)).toEqual(['p1']);
  });
});
