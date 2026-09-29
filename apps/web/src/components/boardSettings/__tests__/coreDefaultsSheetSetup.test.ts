import { describe, expect, it } from 'vitest';
import { CenterSquareType } from '@oybc/shared';
import { nextExplicitCenterForSizeChange } from '../coreDefaultsSheetSetup';

/**
 * Covers `nextExplicitCenterForSizeChange` — the pure centre-coercion rule
 * `CoreDefaultsSheet`'s BOARD-size segmented calls on every size pick (T3,
 * docs/POOLS_RECURRING.md §Per-timeframe size + centre). Mirrors
 * `useBoardWizard.ts`'s `setSize`/`coerceCenterType` pairing — see that
 * hook's own even/odd-crossing rule.
 */
describe('nextExplicitCenterForSizeChange', () => {
  it('forces an explicit NONE when the new size is even (4×4 has no centre)', () => {
    expect(nextExplicitCenterForSizeChange(3, 4, CenterSquareType.FREE)).toBe(CenterSquareType.NONE);
    expect(nextExplicitCenterForSizeChange(5, 4, null)).toBe(CenterSquareType.NONE);
    expect(nextExplicitCenterForSizeChange(4, 4, CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
  });

  it('promotes the NONE an even board forced back to an explicit FREE when crossing even→odd', () => {
    expect(nextExplicitCenterForSizeChange(4, 3, CenterSquareType.NONE)).toBe(CenterSquareType.FREE);
    expect(nextExplicitCenterForSizeChange(4, 5, CenterSquareType.NONE)).toBe(CenterSquareType.FREE);
  });

  it('crossing even→odd from an INHERITED even size also lands on explicit FREE (the resolved centre at 4×4 is always NONE — same as the wizard and iOS)', () => {
    // Global prefs 4×4 + centre None, no override yet: picking 3×3 must not
    // silently inherit "no free space" when iOS / both wizards show FREE.
    expect(nextExplicitCenterForSizeChange(4, 3, null)).toBe(CenterSquareType.FREE);
    expect(nextExplicitCenterForSizeChange(4, 3, CenterSquareType.FREE)).toBe(CenterSquareType.FREE);
  });

  it('never touches the centre override on an odd→odd re-pick (3↔5)', () => {
    expect(nextExplicitCenterForSizeChange(3, 5, CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
    expect(nextExplicitCenterForSizeChange(5, 3, CenterSquareType.FREE)).toBe(CenterSquareType.FREE);
    expect(nextExplicitCenterForSizeChange(3, 5, null)).toBeNull();
    expect(nextExplicitCenterForSizeChange(3, 3, CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
  });
});
