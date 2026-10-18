import { describe, expect, it, vi } from 'vitest';
import { varyRange } from '@oybc/shared';
import { rollExplicitGoal } from '../explicitGoalRoll';

describe('rollExplicitGoal (C2)', () => {
  it('dice off returns the goal untouched and never draws', () => {
    const rng = vi.fn(() => 0.5);
    expect(rollExplicitGoal({ target: 26.25, kind: 'continuous' }, 0, rng)).toEqual({ target: 26.25, kind: 'continuous' });
    expect(rng).not.toHaveBeenCalled();
  });

  it('rolls inside varyRange around the explicit goal, in the goal\'s kind, drawing once', () => {
    const [lo, hi] = varyRange(40, 1, 40, 'discrete');
    const rng = vi.fn(() => 0);
    expect(rollExplicitGoal({ target: 40, kind: 'discrete' }, 1, rng)).toEqual({ target: lo, kind: 'discrete' });
    expect(rng).toHaveBeenCalledTimes(1);
    expect(rollExplicitGoal({ target: 40, kind: 'discrete' }, 1, () => 0.999).target).toBe(hi);
  });

  it('steps in tenths for a continuous goal', () => {
    const [lo, hi] = varyRange(6, 1, 6, 'continuous');
    const low = rollExplicitGoal({ target: 6, kind: 'continuous' }, 1, () => 0);
    const high = rollExplicitGoal({ target: 6, kind: 'continuous' }, 1, () => 0.999);
    expect([low.target, high.target]).toEqual([lo, hi]);
    expect(low.kind).toBe('continuous');
  });
});
