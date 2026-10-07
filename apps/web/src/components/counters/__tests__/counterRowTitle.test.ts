import { describe, expect, it } from 'vitest';
import { counterRowSubtitle, counterRowTitle } from '../counterRowTitle';

describe('counterRowTitle', () => {
  it('continuous / duration / discrete', () => {
    expect(counterRowTitle({ action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' })).toBe('Run 26.2 miles');
    expect(counterRowTitle({ action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' })).toBe('Practice 10h 30m');
    expect(counterRowTitle({ action: 'Read', unit: 'pages', maxCount: 300 })).toBe('Read 300 pages');
  });
  it('null when the fields cannot form a title', () => {
    expect(counterRowTitle({ action: 'Run', unit: '', maxCount: 5 })).toBeNull();
    expect(counterRowTitle({ action: '', unit: 'mi', maxCount: 5 })).toBeNull();
    expect(counterRowTitle({ action: 'Run', unit: 'mi' })).toBeNull();
  });
});

describe('counterRowSubtitle', () => {
  it('shows the kind-aware title unless it restates the row title', () => {
    expect(counterRowSubtitle({ title: 'Marathon', action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' })).toBe('Run 26.2 miles');
    expect(counterRowSubtitle({ title: 'Band', action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' })).toBe('Practice 10h 30m');
    expect(counterRowSubtitle({ title: 'run 26.2 miles', action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' })).toBe('');
    expect(counterRowSubtitle({ title: 'x', action: 'Run', unit: '', maxCount: 5 })).toBe('');
  });
});
