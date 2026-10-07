import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildPoolRowSubtitle } from '../poolRowSubtitle';

const counting = (over: Partial<Task>): Task =>
  ({ id: 't', type: TaskType.COUNTING, title: 'x', action: 'Run', unit: 'mi', maxCount: 26.2, ...over }) as Task;

describe('buildPoolRowSubtitle — counting goal at the task kind', () => {
  it('discrete and continuous carry the unit', () => {
    expect(buildPoolRowSubtitle(counting({ maxCount: 5 }), [])).toBe('Run · goal 5 mi');
    expect(buildPoolRowSubtitle(counting({ countKind: 'continuous' }), [])).toBe('Run · goal 26.2 mi');
  });
  it('duration shows h/m and no unit', () => {
    expect(buildPoolRowSubtitle(counting({ countKind: 'duration', maxCount: 90, unit: '' }), [])).toBe('Run · goal 1h 30m');
  });
});
