import { describe, expect, it } from 'vitest';
import { formatCounterLogToastText } from '../counterLogToastText';

describe('formatCounterLogToastText', () => {
  it('renders the R3 credited increment copy byte-exact', () => {
    expect(
      formatCounterLogToastText({
        amount: 10,
        unit: 'push-ups',
        verb: 'logged',
        counterName: 'Push-ups',
        boardNames: ['Daily Grind'],
      }),
    ).toBe('+10 Push-ups — also counted on Daily Grind.');
  });

  it('renders the R3 credited decrement copy byte-exact', () => {
    expect(
      formatCounterLogToastText({
        amount: 10,
        unit: 'push-ups',
        verb: 'removed',
        counterName: 'Push-ups',
        boardNames: ['Daily Grind'],
      }),
    ).toBe('−10 Push-ups — also removed from Daily Grind.');
  });

  it('joins multiple board names with a comma (existing toast formatting, unchanged)', () => {
    expect(
      formatCounterLogToastText({
        amount: 1,
        unit: 'push-ups',
        verb: 'logged',
        counterName: 'Push-ups',
        boardNames: ['Daily Grind', 'Weekly Warmup'],
      }),
    ).toBe('+1 Push-ups — also counted on Daily Grind, Weekly Warmup.');
  });

  it('falls back to the standalone Hub/Detail copy when boardNames is absent', () => {
    expect(
      formatCounterLogToastText({ amount: 5, unit: 'pages', verb: 'logged' }),
    ).toBe('Logged +5 pages');
    expect(
      formatCounterLogToastText({ amount: 5, unit: 'pages', verb: 'removed' }),
    ).toBe('Removed 5 pages');
  });

  it('falls back to the standalone copy when boardNames is an empty array', () => {
    expect(
      formatCounterLogToastText({
        amount: 5,
        unit: 'pages',
        verb: 'logged',
        counterName: 'Pages',
        boardNames: [],
      }),
    ).toBe('Logged +5 pages');
  });
});
