import { CenterSquareType, type BoardSize, type DefaultCenterSquareType } from '@oybc/shared';

/**
 * T3 (docs/POOLS_RECURRING.md §Per-timeframe size + centre) — the explicit
 * centre override `CoreDefaultsSheet`'s BOARD-size segmented should carry
 * forward when the user picks a new size. Pure so the even/odd coercion
 * (mirrors the wizard's `setSize` / `coerceCenterType` pairing in
 * `useBoardWizard.ts`) is independently unit-testable without rendering
 * the sheet.
 *
 * - A new EVEN size (4×4) always forces an explicit `NONE` — even boards
 *   have no centre concept, so the sheet's saved row should say so
 *   plainly rather than leaving a stale/irrelevant override underneath.
 * - Crossing even→odd (the previous RESOLVED size was even) promotes a
 *   `NONE` that evenness forced back to `FREE` — mirroring the wizard's
 *   "only coerce NONE→FREE when actually crossing even→odd" rule. `null`
 *   (inherit) or any other explicit pick passes through untouched.
 * - An odd→odd re-pick (3↔5) never touches the centre override.
 *
 * @param prevResolvedSize - The size the sheet's controls were showing
 *   (RESOLVED — override or inherited) immediately before this change.
 * @param newSize - The size the user just picked.
 * @param prevExplicitCenter - The centre override state before this
 *   change (`null` = inherit).
 * @returns The centre override state to apply after the size change.
 */
export function nextExplicitCenterForSizeChange(
  prevResolvedSize: BoardSize,
  newSize: BoardSize,
  prevExplicitCenter: DefaultCenterSquareType | null,
): DefaultCenterSquareType | null {
  const oldIsOdd = prevResolvedSize % 2 !== 0;
  const newIsOdd = newSize % 2 !== 0;
  if (!newIsOdd) return CenterSquareType.NONE;
  if (!oldIsOdd && prevExplicitCenter === CenterSquareType.NONE) return CenterSquareType.FREE;
  return prevExplicitCenter;
}
