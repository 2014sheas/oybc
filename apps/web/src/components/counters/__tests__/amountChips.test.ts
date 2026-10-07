import { describe, it, expect } from 'vitest';
import { buildAmountChipOptions, buildBoardQuickAmountOptions, initialChipAmount, parseCustomLogAmount } from '../amountChips';

describe('buildAmountChipOptions', () => {
  it('builds the FIXED 1 / 10 / 25 / # row (no dynamic default chip)', () => {
    expect(buildAmountChipOptions()).toEqual([
      { value: 1, label: '1' },
      { value: 10, label: '10' },
      { value: 25, label: '25' },
      { value: null, label: '#' },
    ]);
  });
});

describe('buildBoardQuickAmountOptions', () => {
  it('builds the FIXED signed +1 / +10 / # row (no fixed 25, no dynamic chip)', () => {
    expect(buildBoardQuickAmountOptions()).toEqual([
      { value: 1, label: '+1' },
      { value: 10, label: '+10' },
      { value: null, label: '#' },
    ]);
  });
});

describe('initialChipAmount', () => {
  it('returns the remembered default when it is a preset', () => {
    expect(initialChipAmount(1)).toBe(1);
    expect(initialChipAmount(10)).toBe(10);
    expect(initialChipAmount(25)).toBe(25);
  });
  it('falls back to 1 for an off-preset or missing default', () => {
    // A fresh counter (no remembered default) must open on +1, matching the
    // one-tap paths (`defaultLogAmount ?? 1`) — not +10.
    expect(initialChipAmount(7)).toBe(1);
    expect(initialChipAmount(null)).toBe(1);
    expect(initialChipAmount(undefined)).toBe(1);
  });
});


describe('parseCustomLogAmount', () => {
  it('accepts positive integers', () => {
    expect(parseCustomLogAmount('7')).toBe(7);
    expect(parseCustomLogAmount('  42  ')).toBe(42);
    expect(parseCustomLogAmount('1000')).toBe(1000);
  });

  it('rejects zero, negatives, decimals, and non-numeric input', () => {
    expect(parseCustomLogAmount('0')).toBeNull();
    expect(parseCustomLogAmount('-5')).toBeNull();
    expect(parseCustomLogAmount('3.5')).toBeNull();
    expect(parseCustomLogAmount('abc')).toBeNull();
    expect(parseCustomLogAmount('')).toBeNull();
    expect(parseCustomLogAmount('   ')).toBeNull();
    expect(parseCustomLogAmount('1e3')).toBeNull();
    expect(parseCustomLogAmount('+5')).toBeNull();
  });
});

describe('amountChips wrappers — counter kinds', () => {
  it('hub chips per kind; board chips per kind; discrete defaults unchanged', () => {
    expect(buildAmountChipOptions().map((c) => c.label)).toEqual(['1', '10', '25', '#']);
    expect(buildAmountChipOptions('duration').map((c) => c.label)).toEqual(['15m', '30m', '1h', '#']);
    expect(buildBoardQuickAmountOptions().map((c) => c.label)).toEqual(['+1', '+10', '#']);
    expect(buildBoardQuickAmountOptions('continuous', 26.2).map((c) => c.label)).toEqual(['6.6', '13.1', '26.2', '#']);
  });
  it('parseCustomLogAmount parses at the kind', () => {
    expect(parseCustomLogAmount('3,1', 'continuous')).toBe(3.1);
    expect(parseCustomLogAmount('3.1')).toBeNull();
    expect(parseCustomLogAmount('1h 30m', 'duration')).toBe(90);
  });
});
