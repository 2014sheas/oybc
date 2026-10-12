import { describe, expect, it } from 'vitest';
import {
  MOMENT_BEAT_MS,
  momentBeatAt,
  shownMomentBeat,
  startMomentClock,
  type MomentScheduler,
} from './useMomentReplay';

/** A manual frame scheduler: `flush(t)` runs the pending callback at time t. */
function manualScheduler() {
  let pending: ((now: number) => void) | null = null;
  let next = 1;
  const cancelled: number[] = [];
  const scheduler: MomentScheduler = {
    request: (cb) => { pending = cb; return next++; },
    cancel: (id) => { cancelled.push(id); pending = null; },
  };
  return {
    scheduler,
    cancelled,
    hasPending: () => pending !== null,
    flush(t: number) { const cb = pending; pending = null; cb?.(t); },
  };
}

describe('momentBeatAt', () => {
  it('holds beat 0 for one cadence, then advances one beat per cadence', () => {
    expect(momentBeatAt(0, 175)).toBe(0);
    expect(momentBeatAt(174, 175)).toBe(0);
    expect(momentBeatAt(175, 175)).toBe(1);
    expect(momentBeatAt(700, 175)).toBe(4);
    expect(momentBeatAt(-50, 175)).toBe(0);
  });

  it('a greenlog ticks faster than a bingo', () => {
    expect(MOMENT_BEAT_MS.greenlog).toBeLessThan(MOMENT_BEAT_MS.bingo);
  });
});

describe('shownMomentBeat', () => {
  it('clamps to the final beat', () => {
    expect(shownMomentBeat(3, 6, false)).toBe(3);
    expect(shownMomentBeat(40, 6, false)).toBe(6);
  });
  it('reduced motion shows the end state immediately', () => {
    expect(shownMomentBeat(0, 6, true)).toBe(6);
  });
});

describe('startMomentClock', () => {
  it('reports beats from the first frame and stops at the final beat', () => {
    const m = manualScheduler();
    const beats: number[] = [];
    startMomentClock({ cadenceMs: 100, finalBeat: 2, start: { current: null }, onBeat: (b) => beats.push(b), scheduler: m.scheduler });
    m.flush(1000);
    m.flush(1100);
    m.flush(1250);
    expect(beats).toEqual([0, 1, 2]);
    expect(m.hasPending()).toBe(false);
  });

  it('a restarted clock resumes from the stored start instead of rewinding', () => {
    const m = manualScheduler();
    const start = { current: 500 as number | null };
    const beats: number[] = [];
    startMomentClock({ cadenceMs: 100, finalBeat: 9, start, onBeat: (b) => beats.push(b), scheduler: m.scheduler });
    m.flush(900);
    expect(beats).toEqual([4]);
  });

  it('the returned stop cancels the pending frame', () => {
    const m = manualScheduler();
    const stop = startMomentClock({ cadenceMs: 100, finalBeat: 9, start: { current: null }, onBeat: () => {}, scheduler: m.scheduler });
    stop();
    expect(m.cancelled).toHaveLength(1);
    expect(m.hasPending()).toBe(false);
  });
});
