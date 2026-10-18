import { anonymiseWorkspace } from '../../src/algorithms/workspaceAnonymiser';
import { isAutoCounterTitle } from '../../src/algorithms/taskTitle';
import { TaskType } from '../../src/constants/enums';
import type { Board, BoardTask, Pool, RecurringBoardTemplate, Task, TaskEvent } from '../../src/types';

const TS = '2026-10-01T00:00:00.000Z';
const task = (id: string, over: Partial<Task>): Task =>
  ({ id, userId: 'real-uid', title: 't', type: TaskType.NORMAL, isCompleted: false, isDeleted: false, totalCompletions: 0, totalInstances: 0, createdAt: TS, updatedAt: TS, version: 1, ...over }) as Task;

describe('anonymiseWorkspace', () => {
  const root = task('r1', { type: TaskType.COUNTING, title: 'Read 20 pages', action: 'Read', unit: 'pages', maxCount: 20, counterName: 'Reading', titleTemplatePlural: 'Finish #N pages', description: 'secret' });
  const linkedAuto = task('d1', { type: TaskType.COUNTING, title: 'Finish 5 pages', action: 'Read', unit: 'pages', maxCount: 5, sharedCounterId: 'r1' });
  const linkedCustom = task('d2', { type: TaskType.COUNTING, title: 'Morning pages', action: 'Read', unit: 'pages', maxCount: 5, sharedCounterId: 'r1' });
  const normal = task('n1', { title: 'Call mum', description: 'private' });
  const board: Board = { id: 'b1', userId: 'real-uid', name: 'Family stuff', description: 'x', status: 'active', boardSize: 3, timeframe: 'weekly', startDate: '2026-10-05T00:00:00', endDate: '2026-10-11T23:59:59.999', centerSquareType: 'none', isRandomized: false, totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: TS, updatedAt: TS, version: 1, isDeleted: false, recurringDraftMix: '{"v":2}' } as Board;
  const bt: BoardTask = { id: 'bt1', boardId: 'b1', taskId: 'r1', row: 0, col: 0, isCenter: false, titleOverride: 'My reading', createdAt: TS, updatedAt: TS, version: 1, isDeleted: false };
  const ev: TaskEvent = { id: 'e1', userId: 'real-uid', taskId: 'r1', kind: 'increment', delta: 3, occurredAt: TS, createdAt: TS, updatedAt: TS, version: 1, isDeleted: false };
  const template = { id: 'tp1', userId: 'real-uid', name: 'Mornings', timeframe: 'daily', boardSize: 3, centerSquareType: 'none', isRandomized: false, seedTaskIds: ['r1'], manualTaskIds: ['r1'], manualTaskTargets: { r1: { target: 5, kind: 'discrete', title: 'Dawn pages' } }, lastSpawnedWindowKey: null, isActive: true, createdAt: TS, updatedAt: TS, version: 1, isDeleted: false } as unknown as RecurringBoardTemplate;
  const pool = { id: 'p1', userId: 'real-uid', name: 'Health', taskIds: ['n1'], createdAt: TS, updatedAt: TS, version: 1, isDeleted: false } as Pool;

  const out = anonymiseWorkspace({ tasks: [root, linkedAuto, linkedCustom, normal], boards: [board], boardTasks: [bt], compoundChildren: [], events: [ev], templates: [template], pools: [pool] });
  const json = JSON.stringify(out);

  it('keeps ids, numbers, dates, kinds and relations', () => {
    expect(out.tasks.map((t) => t.id)).toEqual(['r1', 'd1', 'd2', 'n1']);
    expect(out.tasks[1].sharedCounterId).toBe('r1');
    expect(out.tasks[0].maxCount).toBe(20);
    expect(out.boards[0].startDate).toBe(board.startDate);
    expect(out.boardTasks[0].taskId).toBe('r1');
    expect(out.events[0].delta).toBe(3);
    expect(out.templates[0].manualTaskTargets?.r1.target).toBe(5);
  });

  it('leaks no user text and drops descriptions, the draft blob and the real uid', () => {
    for (const word of ['Read', 'pages', 'Reading', 'Morning', 'Call mum', 'Family', 'Mornings', 'Health', 'My reading', 'Dawn', 'secret', 'private', 'real-uid', '"v":2']) {
      expect(json).not.toContain(word);
    }
    expect(out.tasks[0].description).toBeUndefined();
    expect(out.boards[0].recurringDraftMix).toBeUndefined();
    expect(new Set(out.tasks.map((t) => t.userId))).toEqual(new Set(['owner']));
  });

  it('preserves whether a counting title is the auto formula / template render', () => {
    const [r, dAuto, dCustom] = out.tasks;
    expect(isAutoCounterTitle(r.title, r.action ?? '', r.maxCount, r.unit ?? '', 'discrete', r)).toBe(true);
    expect(isAutoCounterTitle(dAuto.title, dAuto.action ?? '', dAuto.maxCount, dAuto.unit ?? '', 'discrete', r)).toBe(true);
    expect(isAutoCounterTitle(dCustom.title, dCustom.action ?? '', dCustom.maxCount, dCustom.unit ?? '', 'discrete', r)).toBe(false);
  });

  it('is deterministic and maps equal values to equal placeholders', () => {
    const again = anonymiseWorkspace({ tasks: [root, linkedAuto, linkedCustom, normal], boards: [board], boardTasks: [bt], compoundChildren: [], events: [ev], templates: [template], pools: [pool] });
    expect(JSON.stringify(again)).toBe(json);
    expect(out.tasks[0].action).toBe(out.tasks[1].action);
  });
});
