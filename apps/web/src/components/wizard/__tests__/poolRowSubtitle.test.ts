import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildPoolRowSubtitle } from '../poolRowSubtitle';

const counting = (over: Partial<Task>): Task =>
  ({ id: 't', type: TaskType.COUNTING, title: 'x', action: 'Run', unit: 'mi', maxCount: 26.2, ...over }) as Task;

describe('buildPoolRowSubtitle — counting goal at the task kind', () => {
  it('the goal alone — no action or unit', () => {
    expect(buildPoolRowSubtitle(counting({ maxCount: 5 }), [])).toBe('goal 5');
    expect(buildPoolRowSubtitle(counting({ countKind: 'continuous' }), [])).toBe('goal 26.2');
  });
  it('duration shows h/m', () => {
    expect(buildPoolRowSubtitle(counting({ countKind: 'duration', maxCount: 90, unit: '' }), [])).toBe('goal 1h 30m');
  });
});
