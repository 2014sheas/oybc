import { describe, expect, it } from 'vitest';
import { initialLateLogAmount, lateLogCountingModel } from '../lateLogCountingModel';

describe('lateLogCountingModel', () => {
  it('continuous: goal chips, readout, Log +amount unit', () => {
    const m = lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: false, customDraft: '' });
    expect(m.chips.map((c) => c.label)).toEqual(['+6.6', '+13.1', '+26.2']);
    expect(m.chips.map((c) => c.amount)).toEqual([6.6, 13.1, 26.2]);
    expect(m.readout).toEqual({ count: '21.3', max: '26.2', unit: 'mi' });
    expect(m.amount).toBe(6.6);
    expect(m.buttonLabel).toBe('Log +6.6 mi');
  });
  it('a custom 4.9 drives the label and amount; an invalid custom blocks Log', () => {
    const ok = lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: true, customDraft: '4,9' });
    expect(ok.buttonLabel).toBe('Log +4.9 mi');
    expect(ok.amount).toBe(4.9);
    const bad = lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: true, customDraft: '4.999' });
    expect(bad.canLog).toBe(false);
    expect(bad.amount).toBeNull();
    expect(bad.buttonLabel).toBe('Log');
  });
  it('duration: no unit anywhere', () => {
    const m = lateLogCountingModel({ kind: 'duration', goal: 630, count: 540, unit: '', selected: 158, customOpen: true, customDraft: '1h 30m' });
    expect(m.chips[0].label).toBe('+2h 38m');
    expect(m.readout).toEqual({ count: '9h', max: '10h 30m', unit: '' });
    expect(m.amount).toBe(90);
    expect(m.buttonLabel).toBe('Log +1h 30m');
  });
  it('discrete is unchanged: +1 +2 +5 and a plain Log', () => {
    const m = lateLogCountingModel({ kind: 'discrete', goal: 5, count: 0, unit: 'mi', selected: 1, customOpen: false, customDraft: '' });
    expect(m.chips.map((c) => c.label)).toEqual(['+1', '+2', '+5']);
    expect(m.buttonLabel).toBe('Log');
    expect(initialLateLogAmount('discrete', 5)).toBe(1);
    expect(initialLateLogAmount('duration', 630)).toBe(158);
  });
});
