import { describe, expect, it } from 'vitest';
import { kindSwitchConfirmLines, needsKindSwitchConfirm, switchedGoalText } from '../kindSwitchModel';
import { planKindSwitchPreview } from '../../../db/operations/countKindSwitch';

describe('kindSwitchModel', () => {
  it('only continuous → discrete confirms', () => {
    expect(needsKindSwitchConfirm('continuous', 'discrete')).toBe(true);
    expect(needsKindSwitchConfirm('discrete', 'continuous')).toBe(false);
  });
  it('copy matches the handoff', () => {
    const lines = kindSwitchConfirmLines({
      from: 'continuous', to: 'discrete', titleBefore: 'Run 26.2 miles', titleAfter: 'Run 26 miles',
      loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2,
    });
    expect(lines.title).toBe('Switch to Discrete?');
    expect(lines.rows).toEqual([['Run 26.2 miles', 'Run 26 miles'], ['12.75 logged', '13 logged']]);
    expect(lines.body).toBe('Switching back restores the exact values. Follows on 2 linked squares.');
  });
  it('family line: absent at 0, singular at 1', () => {
    const base = { from: 'continuous' as const, to: 'discrete' as const, titleBefore: 'a', titleAfter: 'a', loggedBefore: 0, loggedAfter: 0 };
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 0 }).body).toBe('Switching back restores the exact values.');
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 1 }).body).toBe('Switching back restores the exact values. Follows on 1 linked square.');
  });
  it('switchedGoalText rounds a typed decimal goal for the new whole kind', () => {
    expect(switchedGoalText('26.2', 'continuous', 'discrete')).toBe('26');
    expect(switchedGoalText('0.3', 'continuous', 'discrete')).toBe('1');
    expect(switchedGoalText('26', 'discrete', 'continuous')).toBe('26');
    expect(switchedGoalText('', 'continuous', 'discrete')).toBe('');
  });
  it('a pending task previews from its own fields', () => {
    expect(planKindSwitchPreview({ title: 'Run 26.2 mi', action: 'Run', unit: 'mi', maxCount: 26.2, currentCount: 0, countKind: 'continuous' }, 'discrete', 0))
      .toEqual({ from: 'continuous', to: 'discrete', titleBefore: 'Run 26.2 mi', titleAfter: 'Run 26 mi', loggedBefore: 0, loggedAfter: 0, linkedCount: 0 });
  });
});
