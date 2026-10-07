import { describe, expect, it, vi } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildQuickAmount, initialCountingLogState, type CountingLogContext } from '../countingLogModel';

const task = (over: Partial<Task>): Task => ({
  id: 't', userId: 'u1', title: 'Run 26.2 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2,
  countKind: 'continuous', currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0,
  createdAt: 't', updatedAt: 't', version: 1, isDeleted: false, ...over,
} as Task);

const ctx = (t: Task, over: Partial<CountingLogContext> = {}): CountingLogContext => ({
  boardTaskId: 'bt', task: t, taskMap: { [t.id]: t }, sourceId: null, currentCount: 12.4, isSealed: false,
  onIncrementShared: vi.fn(), onDecrementShared: vi.fn(), onSetStandaloneCount: vi.fn(), onPersistDefault: vi.fn(), ...over,
});

describe('countingLogModel', () => {
  it('a discrete standalone square keeps the plain stepper', () => {
    const c = ctx(task({ countKind: undefined, maxCount: 10, unit: 'reps' }));
    expect(initialCountingLogState(c)).toBeNull();
  });
  it('a discrete shared square keeps +1 · +10 · #', () => {
    const c = ctx(task({ countKind: undefined, maxCount: 200 }), { sourceId: 't' });
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {});
    expect(q?.options.map((o) => o.label)).toEqual(['+1', '+10', '#']);
    expect(q?.addLabel).toBe('+ 1');
  });
  it('a continuous standalone square opens on its remembered custom amount', () => {
    const c = ctx(task({ defaultLogAmount: 3.1 }));
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {})!;
    expect(q).toMatchObject({ kind: 'continuous', isCustomActive: true, amountText: '3.1', selected: 3.1, addLabel: '+ 3.1 mi' });
    expect(q.options.map((o) => o.label)).toEqual(['6.6', '13.1', '26.2', '#']);
  });
  it('adding a custom amount sets the window count and persists the default; a chip does not persist', () => {
    const c = ctx(task({ defaultLogAmount: 3.1 }));
    buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.onAdd();
    expect(c.onSetStandaloneCount).toHaveBeenCalledWith('bt', 15.5);
    expect(c.onPersistDefault).toHaveBeenCalledWith('t', 3.1);
    const c2 = ctx(task({}));
    buildQuickAmount(initialCountingLogState(c2)!, c2, () => {})!.onAdd(); // ¼ chip 6.6 pre-selected
    expect(c2.onSetStandaloneCount).toHaveBeenCalledWith('bt', 19);
    expect(c2.onPersistDefault).not.toHaveBeenCalled();
  });
  it('fixing 31-for-3.1: the field opens on 31 and − removes exactly 31', () => {
    const c = ctx(task({ defaultLogAmount: 31 }), { currentCount: 40 });
    buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.onRemove();
    expect(c.onSetStandaloneCount).toHaveBeenCalledWith('bt', 9);
  });
  it('an invalid field disables + and −', () => {
    const c = ctx(task({}));
    const q = buildQuickAmount({ ...initialCountingLogState(c)!, amountText: '3.125', isCustom: true }, c, () => {})!;
    expect(q.selected).toBeNull();
    expect(q.removeDisabled).toBe(true);
  });
  it('a duration square labels without a unit', () => {
    const c = ctx(task({ countKind: 'duration', maxCount: 630, unit: '' }), { currentCount: 270 });
    expect(buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.addLabel).toBe('+ 2h 38m');
  });
  it('typing a chip value back into the field selects that chip; anything else is custom', () => {
    const c = ctx(task({}));
    const set = vi.fn();
    const q = buildQuickAmount(initialCountingLogState(c)!, c, set)!;
    q.onAmountTextChange('13,1');
    expect(set).toHaveBeenLastCalledWith(expect.objectContaining({ amountText: '13,1', isCustom: false }));
    q.onAmountTextChange('31');
    expect(set).toHaveBeenLastCalledWith(expect.objectContaining({ amountText: '31', isCustom: true }));
    q.onSelectChip(26.2);
    expect(set).toHaveBeenLastCalledWith(expect.objectContaining({ amountText: '26.2', isCustom: false, amount: 26.2 }));
  });
  it('a linked square never removes, and a shared log goes to the source with the custom flag', () => {
    const root = task({ id: 'root', countKind: 'continuous', defaultLogAmount: 3.1 });
    const linked = task({ id: 'lk', sharedCounterId: 'root', countKind: undefined });
    const c = ctx(linked, { taskMap: { root, lk: linked }, sourceId: 'root' });
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {})!;
    expect(q.kind).toBe('continuous');
    expect(q.removeDisabled).toBe(true);
    q.onRemove();
    expect(c.onDecrementShared).not.toHaveBeenCalled();
    q.onAdd();
    expect(c.onIncrementShared).toHaveBeenCalledWith('root', 3.1, true);
  });
  it('a sealed board logs nothing', () => {
    const c = ctx(task({}), { isSealed: true });
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {})!;
    expect(q.busy).toBe(true);
    q.onAdd();
    expect(c.onSetStandaloneCount).not.toHaveBeenCalled();
  });
});
