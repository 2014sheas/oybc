import { describe, expect, it } from 'vitest';
import { formatDefaultsSummary } from '../formatDefaultsSummary';

// Mirrors iOS BoardSettingsView.formatDefaultsSummary(resolvedCount:poolNames:)
// test coverage — see apps/ios/OYBC/Views/ProfileTab/BoardSettingsView.swift.
describe('formatDefaultsSummary', () => {
  it('returns "No default tasks" for a zero (or negative) count, regardless of pool names', () => {
    expect(formatDefaultsSummary(0, [])).toBe('No default tasks');
    expect(formatDefaultsSummary(0, ['Morning Pool'])).toBe('No default tasks');
  });

  it('singularizes "task" for a count of exactly 1 with no pools', () => {
    expect(formatDefaultsSummary(1, [])).toBe('1 default task');
  });

  it('pluralizes "tasks" for counts other than 1 with no pools', () => {
    expect(formatDefaultsSummary(2, [])).toBe('2 default tasks');
  });

  it('appends the single pool name for exactly one pool', () => {
    expect(formatDefaultsSummary(4, ['Morning Pool'])).toBe(
      '4 default tasks · from Morning Pool',
    );
  });

  it('collapses multiple pools to a count', () => {
    expect(formatDefaultsSummary(6, ['Morning Pool', 'Evening Pool'])).toBe(
      '6 default tasks · from 2 pools',
    );
  });
});
