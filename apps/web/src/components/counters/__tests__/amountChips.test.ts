import { describe, it, expect } from 'vitest';
import { buildAmountChipOptions, buildBoardQuickAmountOptions, parseCustomLogAmount } from '../amountChips';

describe('buildAmountChipOptions', () => {
  it('builds the fixed 1 / default / 25 / # chip row', () => {
    expect(buildAmountChipOptions(10)).toEqual([
      { value: 1, label: '1' },
      { value: 10, label: '10' },
      { value: 25, label: '25' },
      { value: null, label: '#' },
    ]);
  });

  it('renders the default chip verbatim even when it collides with 1 or 25', () => {
    expect(buildAmountChipOptions(1)[1]).toEqual({ value: 1, label: '1' });
    expect(buildAmountChipOptions(25)[1]).toEqual({ value: 25, label: '25' });
  });
});

describe('buildBoardQuickAmountOptions', () => {
  it('builds the SIGNED 3-position +1 / +default / # row (R3 contract; no fixed 25 chip)', () => {
    expect(buildBoardQuickAmountOptions(10)).toEqual([
      { value: 1, label: '+1' },
      { value: 10, label: '+10' },
      { value: null, label: '#' },
    ]);
  });

  it('renders the default chip verbatim even when it collides with 1', () => {
    expect(buildBoardQuickAmountOptions(1)).toEqual([
      { value: 1, label: '+1' },
      { value: 1, label: '+1' },
      { value: null, label: '#' },
    ]);
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
