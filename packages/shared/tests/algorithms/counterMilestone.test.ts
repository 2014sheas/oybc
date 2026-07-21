import { nextCounterMilestone, counterMilestoneProgress } from '../../src/algorithms/counterMilestone';

describe('nextCounterMilestone', () => {
  it('returns the first fixed step for 0', () => {
    expect(nextCounterMilestone(0)).toBe(100);
  });

  it('returns the next fixed step when lifetime sits exactly on a step (strictly greater)', () => {
    expect(nextCounterMilestone(100)).toBe(250);
    expect(nextCounterMilestone(1000)).toBe(2500);
  });

  it('returns the next fixed step for a value between two steps', () => {
    expect(nextCounterMilestone(150)).toBe(250);
    expect(nextCounterMilestone(999)).toBe(1000);
  });

  it('walks through every fixed step boundary', () => {
    expect(nextCounterMilestone(99)).toBe(100);
    expect(nextCounterMilestone(249)).toBe(250);
    expect(nextCounterMilestone(499)).toBe(500);
    expect(nextCounterMilestone(2499)).toBe(2500);
    expect(nextCounterMilestone(4999)).toBe(5000);
    expect(nextCounterMilestone(9999)).toBe(10_000);
    expect(nextCounterMilestone(24_999)).toBe(25_000);
    expect(nextCounterMilestone(49_999)).toBe(50_000);
    expect(nextCounterMilestone(99_999)).toBe(100_000);
  });

  it('falls back to the next multiple of 10,000 once past the top fixed step', () => {
    expect(nextCounterMilestone(100_000)).toBe(110_000);
    expect(nextCounterMilestone(100_001)).toBe(110_000);
    expect(nextCounterMilestone(109_999)).toBe(110_000);
    expect(nextCounterMilestone(110_000)).toBe(120_000);
  });

  it('matches the ceil((n+1)/10_000)*10_000 fallback formula for large values', () => {
    expect(nextCounterMilestone(1_234_567)).toBe(1_240_000);
  });
});

describe('counterMilestoneProgress', () => {
  it('computes next/remaining/fraction for a mid-range value', () => {
    expect(counterMilestoneProgress(150)).toEqual({ next: 250, remaining: 100, fraction: 0.6 });
  });

  it('starts at fraction 0 for a fresh (zero) counter', () => {
    expect(counterMilestoneProgress(0)).toEqual({ next: 100, remaining: 100, fraction: 0 });
  });

  it('clamps fraction to 1 and remaining stays accurate even mid-fixed-step', () => {
    const result = counterMilestoneProgress(99);
    expect(result.next).toBe(100);
    expect(result.remaining).toBe(1);
    expect(result.fraction).toBeCloseTo(0.99);
  });

  it('handles the post-top-step fallback range', () => {
    expect(counterMilestoneProgress(100_000)).toEqual({ next: 110_000, remaining: 10_000, fraction: 100_000 / 110_000 });
  });
});
