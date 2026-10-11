import { describe, expect, it } from 'vitest';
import { TaskType } from '@oybc/shared';
import { autoLinkCreateForPreset, typesForPreset } from '../fromCounterMode';

const TYPES = [
  { value: TaskType.NORMAL, label: 'Simple' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.COMPOUND, label: 'Compound' },
  { value: TaskType.ACHIEVEMENT, label: 'Achievement' },
];

describe('from-counter mode (Counter Detail "+ New")', () => {
  it('drops Achievement (absent, not disabled) only when a counter preset is active', () => {
    expect(typesForPreset(TYPES, 'counter-1').map((t) => t.label)).toEqual(['Simple', 'Counting', 'Compound']);
    expect(typesForPreset(TYPES, null)).toEqual(TYPES);
  });

  it('suppresses the auto-link create (no hint, no link) under a preset only', () => {
    const create = (): void => {};
    expect(autoLinkCreateForPreset(create, 'counter-1')).toBeUndefined();
    expect(autoLinkCreateForPreset(create, null)).toBe(create);
    expect(autoLinkCreateForPreset(undefined, null)).toBeUndefined();
  });
});
