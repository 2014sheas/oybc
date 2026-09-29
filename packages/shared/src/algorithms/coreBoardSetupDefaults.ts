import type { BoardSize } from '../constants';
import { CenterSquareType } from '../constants/enums';
import type { CoreBoardDefault } from '../types/coreBoardDefault';
import type { UserPreferences } from '../types/user';

/**
 * Per-timeframe core-board setup defaults (docs/POOLS_RECURRING.md
 * §Per-timeframe size + centre, owner-decided 2026-09-29).
 *
 * A `CoreBoardDefault` row may carry a per-timeframe `defaultBoardSize` /
 * `defaultCenterType` override; an absent field inherits the global
 * `UserPreferences.defaultBoardSize` / `defaultCenterType`. This is the ONE
 * resolver both wizards call at their existing core-prefill point — never
 * read the raw row fields for a board's setup.
 *
 * Swift twin: `apps/ios/OYBC/Helpers/CoreBoardSetupDefaults.swift`, pinned
 * to the same `tests/fixtures/coreBoardSetupDefaultsVectors.json`.
 */

/** The override pair a `CoreBoardDefault` row may carry. */
export type CoreBoardSetupOverrides = Pick<CoreBoardDefault, 'defaultBoardSize' | 'defaultCenterType'>;

/** The global-prefs pair the overrides fall back to. */
export type CoreBoardSetupPrefs = Pick<UserPreferences, 'defaultBoardSize' | 'defaultCenterType'>;

/** Wizard-ready setup: size + a centre already consistent with that size. */
export interface CoreBoardSetupDefaults {
  boardSize: BoardSize;
  /** `FREE` or `NONE` — never `CHOSEN` (a per-board pick, not a default). */
  centerType: CenterSquareType;
}

/**
 * Resolves the size + centre a core board of one timeframe should START
 * with: the row's override where set, else the global preference — then
 * the wizard's even-size rule (a 4×4 has no centre → `NONE`). The result is
 * exactly what web `coerceCenterType(size, desired)` / iOS
 * `BoardWizardViewModel.coerceCenterType` would produce, so a wizard may
 * still run its own coercion afterwards harmlessly.
 *
 * Defaults PRE-FILL setup like pools do; they never own the board — a saved
 * draft or a repeat series keeps its own size (the caller's concern).
 *
 * @param coreDefault - The timeframe's row (or its override pair); `null` /
 *   `undefined` = no row for this timeframe. A `null` field inside the row
 *   is tolerated and treated as absent (the Swift twin's `nil` covers both).
 * @param prefs - The user's global size + centre defaults.
 * @returns The resolved `{ boardSize, centerType }`.
 */
export function resolveCoreBoardSetupDefaults(
  coreDefault: CoreBoardSetupOverrides | null | undefined,
  prefs: CoreBoardSetupPrefs,
): CoreBoardSetupDefaults {
  const boardSize: BoardSize = coreDefault?.defaultBoardSize ?? prefs.defaultBoardSize;
  const desired: CenterSquareType = coreDefault?.defaultCenterType ?? prefs.defaultCenterType;
  const isOdd = boardSize % 2 !== 0;
  return { boardSize, centerType: isOdd ? desired : CenterSquareType.NONE };
}

/**
 * Whether a row explicitly sets EITHER override (size or centre). Drives the
 * Board-settings per-timeframe summary suffix ("3×3 · free space"), which
 * appears only when a timeframe overrides something — an inheriting row
 * shows no suffix even though it still resolves to a size.
 *
 * @param coreDefault - The timeframe's row (or its override pair), or none.
 * @returns `true` when `defaultBoardSize` or `defaultCenterType` is set.
 */
export function hasExplicitCoreBoardSetup(
  coreDefault: CoreBoardSetupOverrides | null | undefined,
): boolean {
  return coreDefault?.defaultBoardSize != null || coreDefault?.defaultCenterType != null;
}
