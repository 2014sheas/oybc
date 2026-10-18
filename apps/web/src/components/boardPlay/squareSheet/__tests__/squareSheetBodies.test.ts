import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { AchievementBody } from '../AchievementBody';
import { ClosedRow } from '../ClosedRow';
import { CompoundBody } from '../CompoundBody';
import { CountingBody } from '../CountingBody';
import { NormalBody } from '../NormalBody';
import type { CompoundChild } from '../../../interactiveTaskSquareUtils';

const noop = () => {};
const html = (el: React.ReactElement): string => renderToStaticMarkup(el);

const counting = (o: Partial<React.ComponentProps<typeof CountingBody>> = {}) =>
  React.createElement(CountingBody, {
    count: 12, goal: 20, kind: 'discrete', unit: 'pages', boardLabel: 'Week 42', busy: false, closedRow: null,
    stripText: null, removeDisabled: false, onLog: noop, onUndo: noop, ...o,
  });

describe('CountingBody', () => {
  it('renders the windowed count, goal line, rest line and the preset + rest + Other chips', () => {
    const out = html(counting());
    expect(out).toContain('>12<');
    expect(out).toContain('/ 20 pages · Week 42');
    expect(out).toContain('8 to go · Week 42');
    expect(out).toContain('>+1<');
    expect(out).toContain('>+10<');
    expect(out).toContain('>+25<');
    expect(out).toContain('+8 ✓');
    expect(out).toContain('>Other…<');
    expect(out).toContain('IN PROGRESS');
  });
  it('omits the rest line + chip once the goal is met and shows DONE', () => {
    const out = html(counting({ count: 20 }));
    expect(out).not.toContain('to go');
    expect(out).not.toContain('✓');
    expect(out).toContain('DONE');
  });
  it('shows no status pill at zero', () => {
    const out = html(counting({ count: 0 }));
    expect(out).not.toContain('IN PROGRESS');
    expect(out).not.toContain('>DONE<');
  });
  it('busy disables every chip but keeps them rendered', () => {
    const out = html(counting({ busy: true }));
    expect(out.match(/<button[^>]*disabled/g)?.length).toBeGreaterThanOrEqual(5);
    expect(out).toContain('>Other…<');
  });
  it('a write in flight with no busy look yet keeps the controls looking live', () => {
    const out = html(counting({ busy: true, dim: false }));
    expect(out.match(/<button[^>]*disabled=""/g)).toBeNull();
    expect(out).toContain('>Other…<');
  });
  it('renders the Undo strip line', () => {
    const out = html(counting({ stripText: 'Logged +5 pages · Week 42' }));
    expect(out).toContain('Logged +5 pages · Week 42');
    expect(out).toContain('>Undo<');
  });
  it('duration: h:m count at 40pt and no unit', () => {
    const out = html(counting({ kind: 'duration', unit: '', count: 270, goal: 630 }));
    expect(out).toContain('4h 30m');
    expect(out).toContain('font-size:40px');
    expect(out).toContain('/ 10h 30m · Week 42');
  });
  it('closed: the lock row replaces the controls', () => {
    const out = html(counting({ closedRow: React.createElement(ClosedRow, { label: 'Closed Oct 11', onLateLog: noop }) }));
    expect(out).toContain('Closed Oct 11');
    expect(out).toContain('Late log…');
    expect(out).not.toContain('Tap to log');
    expect(out).not.toContain('Other…');
  });
});

describe('ClosedRow', () => {
  it('omits Late log… when the square is not routable', () => {
    expect(html(React.createElement(ClosedRow, { label: 'Closed Oct 11' }))).not.toContain('Late log…');
  });
});

const child = (o: Partial<CompoundChild>): CompoundChild => ({ taskId: 'c', title: 'Walk', isCompleted: false, taskType: 'normal', ...o });
const compound = (children: CompoundChild[], o: Partial<React.ComponentProps<typeof CompoundBody>> = {}) =>
  React.createElement(CompoundBody, {
    children, done: false, boardLabel: 'Today', busy: false, closedRow: null, blockedChildIds: new Set<string>(), openChildId: null,
    stripText: null, toggleStripText: null, onUndoToggle: noop,
    onToggleChild: noop, onUnfoldChild: noop, onLogChild: noop, onUndoChild: noop, onOpenChild: noop, ...o,
  });
const COUNT = { current: 12, max: 20, unit: 'pages', kind: 'discrete' as const, step: 1 };

describe('CompoundBody', () => {
  const kids = [
    child({ taskId: 'a', title: 'Walk', isCompleted: true }),
    child({ taskId: 'b', title: 'Read', taskType: 'counting', count: COUNT }),
    child({ taskId: 'c', title: 'Stretch' }),
  ];
  it('shows the done count, sub-task line, segments, checkbox rows and a + box for the counting child', () => {
    const out = html(compound(kids));
    expect(out).toContain('>1<');
    expect(out).toContain('of 3 sub-tasks · Today');
    expect(out).toContain('role="checkbox"');
    expect(out).toContain('aria-label="Log Read"');
    expect(out).toContain('>+<');
    expect(out).toContain('12 / 20');
    expect(out).toContain('IN PROGRESS');
  });
  it('unfolds the open counting child with a compact chip row and its strip', () => {
    const out = html(compound(kids, { openChildId: 'b', stripText: 'Logged +5 pages · Today' }));
    expect(out).toContain('aria-expanded="true"');
    expect(out).toContain('>+1<');
    expect(out).toContain('Logged +5 pages · Today');
    expect(out).not.toContain('− Remove…');
  });
  it('keeps the + unfold enabled while busy; boxes and chips disable', () => {
    const out = html(compound(kids, { busy: true, openChildId: 'b' }));
    expect(out).toMatch(/aria-label="Log Read"(?![^>]*disabled)/);
    expect(out).toMatch(/role="checkbox"[^>]*disabled/);
    expect(out).toMatch(/<button[^>]*disabled[^>]*>\+10</);
  });
  it('a completed child held by a sealed window cannot be un-completed', () => {
    const out = html(compound(kids, { blockedChildIds: new Set(['a']) }));
    expect(out).toMatch(/aria-checked="true"[^>]*disabled|disabled[^>]*aria-checked="true"/);
  });
  it('shows the checklist toggle strip', () => {
    expect(html(compound(kids, { toggleStripText: 'Walk · done' }))).toContain('Walk · done');
  });
  it('does not unfold in a closed sheet and renders the lock row', () => {
    const out = html(compound(kids, { openChildId: 'b', closedRow: React.createElement(ClosedRow, { label: 'Closed Oct 11' }) }));
    expect(out).not.toContain('role="checkbox"');
    expect(out).not.toContain('>Other…<');
    expect(out).toContain('Closed Oct 11');
  });
});

describe('AchievementBody', () => {
  const base = { statusLabel: 'Watching', timeframeLabel: 'Core · monthly', daysLeft: '14 days left', watchedName: 'October', progress: '0 / 1 bingo' };
  it('shows the watched-board card and Open ‹board›', () => {
    const out = html(React.createElement(AchievementBody, { ...base, onOpenBoard: noop }));
    expect(out).toContain('Watched board');
    expect(out).toContain('Core · monthly');
    expect(out).toContain('14 days left');
    expect(out).toContain('0 / 1 bingo');
    expect(out).toContain('Open October');
  });
  it('omits Open when there is no single board', () => {
    expect(html(React.createElement(AchievementBody, base))).not.toContain('Open October');
  });
});

describe('NormalBody', () => {
  const normal = (o: Partial<React.ComponentProps<typeof NormalBody>>) =>
    html(React.createElement(NormalBody, { done: false, busy: false, blocked: false, closedRow: null, onToggle: noop, ...o }));
  it('Mark done ↔ Done', () => {
    expect(normal({})).toContain('Mark done');
    expect(normal({ done: true })).toContain('>Done<');
  });
  it('un-completing is disabled only when a sealed window holds the completion', () => {
    expect(normal({ done: true, blocked: true })).toMatch(/<button[^>]*disabled/);
    expect(normal({ done: false, blocked: true })).not.toMatch(/<button[^>]*disabled/);
  });
});
