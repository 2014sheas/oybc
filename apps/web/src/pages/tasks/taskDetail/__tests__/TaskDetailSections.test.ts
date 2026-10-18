import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type Task } from '@oybc/shared';
import { RisoReturnPill, RisoToolbarPill } from '../../../../components/riso';
import { useTaskDetail, type TaskDetailData } from '../../../../hooks/useTaskDetail';
import { DetailMenu } from '../DetailMenu';
import { TaskDetailSections } from '../TaskDetailSections';
import type { BoardRow, DetailSegment } from '../taskDetailModel';

const noop = () => {};
const task = (o: Partial<Task> = {}): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', version: 1, isDeleted: false, ...o,
}) as Task;
const row = (o: Partial<BoardRow> = {}): BoardRow => ({
  boardId: 'b1', name: 'Week 42', badge: 'Core · weekly', caption: 'This week · ends Sun · 2 days left', value: '12/20', done: false,
  fraction: 0.6, draft: false, active: true, missed: false, endDate: null, ...o,
});
const data = (o: Partial<TaskDetailData> = {}): TaskDetailData => ({
  placementsLoaded: true, placements: [], boards: [], anchor: undefined, childDone: {}, rows: [], parentCompounds: [], children: [], counterRoot: null,
  templates: [], watchedBoard: null, watchedTemplate: null,
  activity: { rows: [
    { key: 'a', kind: 'logged', at: '2026-10-12T09:00:00', text: 'Logged +5 pages · Week 42' },
    { key: 'b', kind: 'created', at: '2026-10-01T09:00:00', text: 'Created' },
  ], completionCount: 3 },
  ...o,
});
const render = (segment: DetailSegment, d: TaskDetailData, t: Task = task()): string =>
  renderToStaticMarkup(React.createElement(TaskDetailSections, {
    task: t, data: d, segment, onSegment: noop, onOpenTask: noop, onOpenBoard: noop, onOpenCounter: noop,
  }));

describe('TaskDetailSections', () => {
  it('All: On boards now with its jump, Subtask of, and the two latest Activity lines', () => {
    const parent = task({ id: 'p', title: 'Daily wellness', type: TaskType.COMPOUND });
    const out = render('all', data({ rows: [row()], parentCompounds: [parent] }));
    expect(out).toContain('On boards now · 1');
    expect(out).toContain('All boards');
    expect(out).toContain('Open board Week 42');
    expect(out).toContain('12/20');
    expect(out).toContain('Core · weekly');
    expect(out).toContain('Subtask of');
    expect(out).toContain('Full activity');
    expect(out).toContain('Logged +5 pages · Week 42');
    expect(out).toContain('Boards · 1');
  });

  it('All: no placements reads "Not on a board"', () => {
    expect(render('all', data())).toContain('Not on a board');
  });

  it('Boards: active rows then Past & drafts with Draft badge and dashed ring', () => {
    const out = render('boards', data({ rows: [row(), row({ boardId: 'b2', name: 'Old', active: false, caption: 'Oct 5 · expired', value: null }), row({ boardId: 'b3', name: 'Soon', active: false, draft: true, caption: 'Draft' })] }));
    expect(out).toContain('Past &amp; drafts · 2');
    expect(out).toContain('>Draft<');
    expect(out).toContain('dashed');
    expect(out).not.toContain('All boards');
  });

  it('Links: counter, parents, sub-tasks, watched board and repeating boards', () => {
    const root = task({ id: 'r', title: 'Read', type: TaskType.COUNTING, action: 'Read', unit: 'pages', currentCount: 1240 });
    const linked = task({ type: TaskType.COUNTING, sharedCounterId: 'r' });
    const out = render('links', data({ counterRoot: root }), linked);
    expect(out).toContain('Shared counter');
    expect(out).toContain('1,240 pages');
    const compound = task({ type: TaskType.COMPOUND });
    const child = task({ id: 'c', title: 'Walk', isCompleted: true });
    // A tick only where the anchor's window says done (none without an anchor).
    const out2 = render('links', data({ childDone: { c: true }, children: [{ link: { id: 'l', compoundTaskId: 't', childTaskId: 'c', childIndex: 0 } as never, task: child }] }), compound);
    expect(out2).toContain('Sub-tasks (1) · all of 1');
    expect(out2).toContain('Open subtask: Walk');
    const ach = task({ type: TaskType.ACHIEVEMENT, referencedBoardId: 'wb' });
    const wb = { id: 'wb', name: 'October', status: BoardStatus.ACTIVE, timeframe: Timeframe.MONTHLY, centerSquareType: CenterSquareType.NONE } as unknown as Board;
    expect(render('links', data({ watchedBoard: wb }), ach)).toContain('Watches board');
    expect(render('links', data({ watchedBoard: wb }), ach)).toContain('Greenlog');
    expect(render('links', data({ watchedBoard: null }), ach)).toContain('Board unavailable');
    const tpl = render('links', data({ templates: [{ id: 'x', name: 'Mornings' } as never] }));
    expect(tpl).toContain('Part of repeating board');
    expect(tpl).toContain('Mornings');
    expect(tpl).not.toMatch(/<button[^>]*Part of repeating board/);
    expect(render('links', data())).toContain('No links');
  });

  it('Activity: dots, rows and the footer', () => {
    const out = render('activity', data());
    expect(out).toContain('Oct 12');
    expect(out).toContain('var(--riso-blue)');
    expect(out).toContain('Completed 3× all-time');
    // A Counting task logs increments, not completions: no count (#384).
    const counting = render('activity', data(), task({ type: TaskType.COUNTING }));
    expect(counting).not.toContain('× all-time');
    expect(counting).toContain('Updated ');
  });

  it('Activity footer while the feed is loading: the update time alone, never a placeholder count', () => {
    const loading = render('activity', data({ activity: undefined }));
    expect(loading).not.toContain('× all-time');
    expect(loading).toContain('Updated ');
  });
});

describe('kit pills + menu + data hook (first render)', () => {
  it('the return pill names the previous task; the toolbar pill is the Done label', () => {
    expect(renderToStaticMarkup(React.createElement(RisoReturnPill, { title: 'Read 20 pages', type: 'counting', onClick: noop }))).toContain('Back to Read 20 pages');
    expect(renderToStaticMarkup(React.createElement(RisoToolbarPill, { onClick: noop, onBand: true, children: 'Done' }))).toContain('>Done<');
  });
  it('the menu starts closed, with the options button', () => {
    const out = renderToStaticMarkup(React.createElement(DetailMenu, { onDelete: noop, onOpenCounterSettings: noop }));
    expect(out).toContain('aria-label="Task options"');
    expect(out).not.toContain('role="menu"');
  });
  it('useTaskDetail renders its not-yet-loaded shape', () => {
    let out: TaskDetailData | undefined;
    function Harness(): null { out = useTaskDetail(task()); return null; }
    renderToStaticMarkup(React.createElement(Harness));
    expect(out).toMatchObject({ placementsLoaded: false, anchor: undefined, rows: [], parentCompounds: [], children: [], templates: [] });
  });
});
