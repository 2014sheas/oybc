import { describe, expect, it } from 'vitest';
import {
  childMeta, closedLabel, liveStrip, daysLeftLabel, entryAmount, goalLine, heroCountSize, isLateLogRoutable, logStripText,
  progressPill, restLine, restToGo, subtaskLine,
} from '../squareSheetModel';
import { normalToastLines } from '../useSquareToasts';

describe('squareSheetModel', () => {
  it('status pill: none at zero, in progress partway, done once met', () => {
    expect(progressPill(false, false)).toBeNull();
    expect(progressPill(false, true)).toBe('inProgress');
    expect(progressPill(true, true)).toBe('completed');
  });

  it('rest to go: remaining of the window goal, never negative (overshoot is valid)', () => {
    expect(restToGo(20, 12)).toBe(8);
    expect(restToGo(20, 20)).toBe(0);
    expect(restToGo(20, 25)).toBe(0);
    expect(restToGo(26.2, 12.4)).toBeCloseTo(13.8);
  });

  it('duration shrinks the hero count to 40pt', () => {
    expect(heroCountSize('duration')).toBe(40);
    expect(heroCountSize('discrete')).toBe(52);
    expect(heroCountSize('continuous')).toBe(52);
  });

  it('formats the copy lines per kind', () => {
    expect(logStripText('logged', 5, 'discrete', 'pages', 'Week 42')).toBe('Logged +5 pages · Week 42');
    expect(logStripText('removed', 5, 'discrete', 'pages', 'Week 42')).toBe('Removed 5 pages · Week 42');
    expect(logStripText('logged', 90, 'duration', '', 'Week 42')).toBe('Logged +1h 30m · Week 42');
    expect(goalLine(20, 'discrete', 'pages', 'Week 42')).toBe('/ 20 pages · Week 42');
    expect(goalLine(630, 'duration', '', 'Week 42')).toBe('/ 10h 30m · Week 42');
    expect(restLine(8, 'discrete', 'Week 42')).toBe('8 to go · Week 42');
    expect(childMeta(12, 20, 'discrete')).toBe('12 / 20');
    expect(subtaskLine(3, 'Today')).toBe('of 3 sub-tasks · Today');
    expect(subtaskLine(1, 'Today')).toBe('of 1 sub-task · Today');
  });

  it('closed label names the seal date; an unparseable date reads plain Closed', () => {
    expect(closedLabel('2026-10-11T12:00:00')).toBe('Closed Oct 11');
    expect(closedLabel(null)).toBe('Closed');
    expect(closedLabel('nope')).toBe('Closed');
  });

  it('late log is routable except for achievement squares and hub-linked counters', () => {
    expect(isLateLogRoutable('counting', false)).toBe(true);
    expect(isLateLogRoutable('normal', false)).toBe(true);
    expect(isLateLogRoutable('compound', false)).toBe(true);
    expect(isLateLogRoutable('achievement', false)).toBe(false);
    expect(isLateLogRoutable('counting', true)).toBe(false);
  });

  it('days left: ceil to whole days; null once over or open-ended', () => {
    const now = Date.parse('2026-10-17T12:00:00Z');
    expect(daysLeftLabel('2026-10-31T12:00:00Z', now)).toBe('14 days left');
    expect(daysLeftLabel('2026-10-18T00:00:00Z', now)).toBe('Last day');
    expect(daysLeftLabel('2026-10-19T00:00:00Z', now)).toBe('2 days left');
    expect(daysLeftLabel('2026-10-01T00:00:00Z', now)).toBeNull();
    expect(daysLeftLabel(null, now)).toBeNull();
  });

  it('entry amount: positive parsed values only, quantized', () => {
    expect(entryAmount(null)).toBeNull();
    expect(entryAmount(0)).toBeNull();
    expect(entryAmount(-2)).toBeNull();
    expect(entryAmount(3.1)).toBe(3.1);
  });
});

describe('liveStrip', () => {
  it('shows a strip only while no later write has settled; none stays none', () => {
    const strip = { seq: 4, text: 'Logged +5 pages · Week 42' };
    expect(liveStrip(strip, 4)).toBe(strip);
    expect(liveStrip(strip, 5)).toBeNull();
    expect(liveStrip(null, 5)).toBeNull();
  });
});

describe('normalToastLines', () => {
  it('names the title, new state and board', () => {
    expect(normalToastLines('Finish Dune', true, 'Week 42')).toEqual({ text: 'Finish Dune · done', detail: 'Week 42' });
    expect(normalToastLines('Finish Dune', false, 'Week 42').text).toBe('Finish Dune · not done');
  });
  it('appends the credited counter', () => {
    expect(normalToastLines('Finish Dune', true, 'Week 42', { amount: 1, counterName: 'Books' }).detail).toBe('Week 42 · +1 Books');
    expect(normalToastLines('Run', true, 'Week 42', { amount: 2.5, counterName: 'Miles', kind: 'continuous' }).detail).toBe('Week 42 · +2.5 Miles');
  });
});
