import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import {
  effectiveInlineKind,
  evaluateSubtaskReadiness,
  inlineSubtaskToAutoCreate,
  type InlineSubtaskDraft,
} from '../compoundSubtaskDraft';

const draft = (o: Partial<InlineSubtaskDraft>): InlineSubtaskDraft => ({
  id: 'd', mode: 'inline', inlineType: 'counting', title: '', action: 'Practice', unit: '', maxCountStr: '1h 30m', steps: [], ...o,
});

/** A Discrete / Continuous root counter "Run mi". */
const root = (kind: 'discrete' | 'continuous'): Task => ({
  id: 'root', userId: 'u', title: 'Run 5 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 5,
  currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: 'x', updatedAt: 'x',
  version: 1, isDeleted: false, ...(kind === 'continuous' ? { countKind: 'continuous' as const } : {}),
}) as Task;

describe('inline counting sub-task — counter kinds', () => {
  it('a blank-titled Duration sub-task gets a generated title, minutes and no unit', () => {
    expect(inlineSubtaskToAutoCreate(draft({ countKind: 'duration' }), [])).toEqual({
      autoCreate: { type: TaskType.COUNTING, title: 'Practice 1h 30m', action: 'Practice', unit: undefined, maxCount: 90, countKind: 'duration', sharedCounterId: undefined, baseline: undefined },
    });
  });
  it('a continuous sub-task keeps its typed title and decimal goal', () => {
    const entry = inlineSubtaskToAutoCreate(draft({ countKind: 'continuous', title: 'Long run', action: 'Run', unit: 'mi', maxCountStr: '3,1' }), []);
    expect(entry.autoCreate).toMatchObject({ title: 'Long run', maxCount: 3.1, countKind: 'continuous', unit: 'mi' });
  });
  it('readiness: duration needs no unit; continuous refuses 3 places', () => {
    expect(evaluateSubtaskReadiness(draft({ countKind: 'duration' }), new Set()).ready).toBe(true);
    expect(evaluateSubtaskReadiness(draft({ countKind: 'continuous', unit: 'mi', maxCountStr: '3.125' }), new Set()).ready).toBe(false);
  });

  describe('auto-linked sub-task follows its root kind (picker may show another)', () => {
    const linked = (o: Partial<InlineSubtaskDraft>) => draft({ action: 'Run', unit: 'mi', ...o });
    it('effective kind is the root kind unless opted out', () => {
      expect(effectiveInlineKind(linked({ countKind: 'discrete' }), [root('continuous')])).toBe('continuous');
      expect(effectiveInlineKind(linked({ countKind: 'discrete', linkDisabled: true }), [root('continuous')])).toBe('discrete');
    });
    it('saves a Continuous goal at the root kind though the picker said Discrete', () => {
      const entry = inlineSubtaskToAutoCreate(linked({ countKind: 'discrete', maxCountStr: '3.1' }), [root('continuous')]);
      expect(entry.autoCreate).toMatchObject({ maxCount: 3.1, countKind: 'continuous', sharedCounterId: 'root' });
      expect(evaluateSubtaskReadiness(linked({ countKind: 'discrete', maxCountStr: '3.1' }), new Set(), [root('continuous')]).ready).toBe(true);
    });
    it('linked + invalid goal at the ROOT kind is not ready even though the picker kind would accept it', () => {
      const d = linked({ countKind: 'continuous', maxCountStr: '3.1' });
      expect(evaluateSubtaskReadiness(d, new Set(), []).ready).toBe(true);
      expect(evaluateSubtaskReadiness(d, new Set(), [root('discrete')]).ready).toBe(false);
    });
  });
});
