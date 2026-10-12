import { describe, expect, it } from 'vitest';
import type { BoardMomentReplay } from '@oybc/shared';
import type { BoardCellModel } from '../board/RisoBoardCell';
import { isMomentReady, momentOpenDecision, nextMomentSnapshot, momentDisplayCell, momentPopPhase } from './boardMomentUi';

const replay = (over: Partial<BoardMomentReplay> = {}): BoardMomentReplay => ({
  order: [
    { boardTaskId: 'a', idx: 0, completedAt: null },
    { boardTaskId: 'b', idx: 1, completedAt: null },
  ],
  freeIdx: 4,
  lineClosureBeat: { row_0: 3 },
  completedTasks: 3,
  totalTasks: 9,
  size: 3,
  ...over,
});

const model = (over: Partial<BoardCellModel> = {}): BoardCellModel => ({
  key: 'k', label: 'Task', type: 'normal', done: true, isFree: false, isLine: true, isShared: true, locked: true, ...over,
});

describe('isMomentReady', () => {
  it('a bingo is ready once every new line closes in the replay', () => {
    expect(isMomentReady(replay(), { kind: 'bingo', newLineIds: ['row_0'] })).toBe(true);
    expect(isMomentReady(replay(), { kind: 'bingo', newLineIds: ['row_0', 'col_0'] })).toBe(false);
  });
  it('waits for the rail counter to cover the ordered cells', () => {
    expect(isMomentReady(replay({ completedTasks: 2 }), { kind: 'bingo', newLineIds: ['row_0'] })).toBe(false);
  });
  it('a greenlog is ready only when every cell has landed', () => {
    expect(isMomentReady(replay(), { kind: 'greenlog', newLineIds: [] })).toBe(false);
    const full = replay({
      order: Array.from({ length: 8 }, (_, i) => ({ boardTaskId: `t${i}`, idx: i < 4 ? i : i + 1, completedAt: null })),
      completedTasks: 9,
    });
    expect(isMomentReady(full, { kind: 'greenlog', newLineIds: [] })).toBe(true);
  });
});

describe('momentDisplayCell', () => {
  const none = { landed: false, green: false, popToken: null };
  it('a landed cell is done in its type colour with no ring / marker / chip', () => {
    const c = momentDisplayCell(model({ done: false }), { landed: true, green: false, popToken: 1 }, true);
    expect(c).toMatchObject({ done: true, lineGreen: false, isLine: false, isShared: undefined, locked: undefined });
  });
  it('a green cell is lineGreen', () => {
    expect(momentDisplayCell(model(), { landed: true, green: true, popToken: 2 }, true).lineGreen).toBe(true);
  });
  it('a cell still to land is undone with an empty counting bar', () => {
    const counting = model({ type: 'counting', count: { cur: 20, max: 20, kind: 'discrete' } });
    expect(momentDisplayCell(counting, none, true)).toMatchObject({ done: false, count: { cur: 0, max: 20 } });
  });
  it('a cell that never completes keeps its current count', () => {
    const counting = model({ type: 'counting', done: false, count: { cur: 12, max: 20, kind: 'discrete' } });
    expect(momentDisplayCell(counting, none, false).count?.cur).toBe(12);
  });
  it('the FREE centre stays FREE and only gains lineGreen', () => {
    const free = model({ isFree: true });
    expect(momentDisplayCell(free, none, false)).toMatchObject({ isFree: true, lineGreen: false });
    expect(momentDisplayCell(free, { landed: false, green: true, popToken: 3 }, false).lineGreen).toBe(true);
  });
});

describe('momentPopPhase', () => {
  it('maps landed / green and is null when motion is reduced or the cell is idle', () => {
    expect(momentPopPhase({ landed: true, green: false, popToken: 1 }, true)).toBe('land');
    expect(momentPopPhase({ landed: true, green: true, popToken: 2 }, true)).toBe('green');
    expect(momentPopPhase({ landed: false, green: false, popToken: null }, true)).toBeNull();
    expect(momentPopPhase({ landed: true, green: true, popToken: 2 }, false)).toBeNull();
  });
});

describe('momentOpenDecision', () => {
  it('schedules when idle', () => {
    expect(momentOpenDecision('idle', null, 'bingo')).toBe('schedule');
    expect(momentOpenDecision('idle', null, 'greenlog')).toBe('schedule');
  });
  it('a greenlog replaces a pending bingo', () => {
    expect(momentOpenDecision('pending', 'bingo', 'greenlog')).toBe('schedule');
  });
  it('a bingo never replaces anything, and a pending greenlog is kept', () => {
    expect(momentOpenDecision('pending', 'bingo', 'bingo')).toBe('ignore');
    expect(momentOpenDecision('pending', 'greenlog', 'bingo')).toBe('ignore');
    expect(momentOpenDecision('pending', 'greenlog', 'greenlog')).toBe('ignore');
  });
  it('nothing interrupts an open moment', () => {
    expect(momentOpenDecision('open', null, 'greenlog')).toBe('ignore');
    expect(momentOpenDecision('open', null, 'bingo')).toBe('ignore');
  });
});

describe('nextMomentSnapshot', () => {
  const snap = (n: number) => ({ replay: replay({ completedTasks: n }), cells: [] });
  it('waits until the board shows the outcome or the wait runs out', () => {
    expect(nextMomentSnapshot(null, snap(1), false, false)).toBeNull();
    expect(nextMomentSnapshot(null, null, true, true)).toBeNull();
  });
  it('takes the live snapshot once ready or forced', () => {
    const live = snap(2);
    expect(nextMomentSnapshot(null, live, true, false)).toBe(live);
    expect(nextMomentSnapshot(null, live, false, true)).toBe(live);
  });
  it('freezes: a later live snapshot never replaces the held one', () => {
    const held = snap(3);
    expect(nextMomentSnapshot(held, snap(9), true, true)).toBe(held);
  });
});
