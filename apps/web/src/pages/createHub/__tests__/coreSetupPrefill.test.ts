import { describe, expect, it } from 'vitest';
import { CenterSquareType, type CoreBoardSetupPrefs } from '@oybc/shared';
import { resolveCoreSetupPrefill } from '../coreSetupPrefill';

/**
 * Covers `resolveCoreSetupPrefill` — the pure guard the wizard's one-shot
 * CoreBoardDefault prefill effect (`useBoardWizard.ts`) calls to decide
 * whether/what size+centre to apply (T2, docs/POOLS_RECURRING.md
 * §Per-timeframe size + centre). `useBoardWizard` itself is not exercised
 * here — see `wizardTimeframeSeed.test.ts`'s doc comment for why (no DOM/
 * jsdom harness in this repo's Vitest setup).
 */
describe('resolveCoreSetupPrefill', () => {
  const prefs: CoreBoardSetupPrefs = {
    defaultBoardSize: 5,
    defaultCenterType: CenterSquareType.FREE,
  };

  it('returns null when the user already touched size/centre — never stomps their edit', () => {
    expect(resolveCoreSetupPrefill({ defaultBoardSize: 3, defaultCenterType: CenterSquareType.NONE }, prefs, true)).toBeNull();
    expect(resolveCoreSetupPrefill(null, prefs, true)).toBeNull();
  });

  it('resolves the row override when present and untouched', () => {
    expect(
      resolveCoreSetupPrefill({ defaultBoardSize: 3, defaultCenterType: CenterSquareType.NONE }, prefs, false),
    ).toEqual({ boardSize: 3, centerType: CenterSquareType.NONE });
  });

  it('inherits prefs when the row is null (no default configured) and untouched', () => {
    expect(resolveCoreSetupPrefill(null, prefs, false)).toEqual({
      boardSize: 5,
      centerType: CenterSquareType.FREE,
    });
  });

  it('inherits prefs when the row is undefined (still loading, but caller only calls once resolved)', () => {
    expect(resolveCoreSetupPrefill(undefined, prefs, false)).toEqual({
      boardSize: 5,
      centerType: CenterSquareType.FREE,
    });
  });

  it('applies the even-size coercion via the shared resolver (4×4 has no centre)', () => {
    expect(
      resolveCoreSetupPrefill({ defaultBoardSize: 4, defaultCenterType: CenterSquareType.FREE }, prefs, false),
    ).toEqual({ boardSize: 4, centerType: CenterSquareType.NONE });
  });

  it('resolves a partial override (size only) against prefs for the other field', () => {
    expect(resolveCoreSetupPrefill({ defaultBoardSize: 3 }, prefs, false)).toEqual({
      boardSize: 3,
      centerType: CenterSquareType.FREE, // inherited
    });
  });
});
