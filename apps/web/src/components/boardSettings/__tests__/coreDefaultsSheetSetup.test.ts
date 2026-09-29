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

  it('promotes a NONE that evenness forced back to FREE when crossing even→odd', () => {
    expect(nextExplicitCenterForSizeChange(4, 3, CenterSquareType.NONE)).toBe(CenterSquareType.FREE);
    expect(nextExplicitCenterForSizeChange(4, 5, CenterSquareType.NONE)).toBe(CenterSquareType.FREE);
  });

  it('leaves inherit (null) alone when crossing even→odd — never invents an explicit pick', () => {
    expect(nextExplicitCenterForSizeChange(4, 3, null)).toBeNull();
  });

  it('preserves a non-NONE explicit pick when crossing even→odd (defensive; unreachable in practice since even always forces NONE)', () => {
    expect(nextExplicitCenterForSizeChange(4, 3, CenterSquareType.FREE)).toBe(CenterSquareType.FREE);
  });

  it('never touches the centre override on an odd→odd re-pick (3↔5)', () => {
    expect(nextExplicitCenterForSizeChange(3, 5, CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
    expect(nextExplicitCenterForSizeChange(5, 3, CenterSquareType.FREE)).toBe(CenterSquareType.FREE);
    expect(nextExplicitCenterForSizeChange(3, 5, null)).toBeNull();
    expect(nextExplicitCenterForSizeChange(3, 3, CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
  });
});
