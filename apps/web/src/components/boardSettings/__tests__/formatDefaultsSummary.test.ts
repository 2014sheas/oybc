import { describe, expect, it } from 'vitest';
import { CenterSquareType } from '@oybc/shared';
import { formatDefaultsSummary, formatSetupSuffix } from '../formatDefaultsSummary';

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

  // Per-timeframe size + centre (docs/POOLS_RECURRING.md, 2026-09-29): the
  // suffix appears ONLY when the caller passes an explicit setup — an
  // inheriting timeframe passes nothing and reads exactly as before.
  describe('setup suffix', () => {
    it('is omitted when no setup is passed (inheriting timeframe) — every legacy string is unchanged', () => {
      expect(formatDefaultsSummary(0, [], undefined)).toBe('No default tasks');
      expect(formatDefaultsSummary(4, ['Morning Pool'], undefined)).toBe('4 default tasks · from Morning Pool');
    });

    it('appends "3×3 · free space" for an odd size with a free centre', () => {
      expect(formatDefaultsSummary(4, ['Morning Pool'], { boardSize: 3, centerType: CenterSquareType.FREE })).toBe(
        '4 default tasks · from Morning Pool · 3×3 · free space',
      );
    });

    it('appends "5×5 · no free space" for an odd size with no centre', () => {
      expect(formatDefaultsSummary(2, [], { boardSize: 5, centerType: CenterSquareType.NONE })).toBe(
        '2 default tasks · 5×5 · no free space',
      );
    });

    it('appends a bare "4×4" for an even size (no centre concept, whatever the centre value)', () => {
      expect(formatDefaultsSummary(1, [], { boardSize: 4, centerType: CenterSquareType.NONE })).toBe(
        '1 default task · 4×4',
      );
      expect(formatSetupSuffix({ boardSize: 4, centerType: CenterSquareType.FREE })).toBe('4×4');
    });

    it('still appends after "No default tasks" (a timeframe can set a size with no tasks)', () => {
      expect(formatDefaultsSummary(0, ['Ignored'], { boardSize: 3, centerType: CenterSquareType.NONE })).toBe(
        'No default tasks · 3×3 · no free space',
      );
    });
  });
});
