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
  it('falls back to 10 for an off-preset or missing default', () => {
    expect(initialChipAmount(7)).toBe(10);
    expect(initialChipAmount(null)).toBe(10);
    expect(initialChipAmount(undefined)).toBe(10);
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
