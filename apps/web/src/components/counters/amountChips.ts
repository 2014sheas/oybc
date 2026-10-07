import { boardSheetChips, hubChips, parseCountInput, type CountKind } from '@oybc/shared';

/**
 * amountChips.ts — pure helpers backing the Counter Detail Log card's
 * amount-chip row (R2 Counters UX refresh — design handoff §Counter Detail,
 * chips "1 / {default} / 25 / #"). Kept side-effect-free so the chip-set
 * shape and the custom-input validation are unit-testable without a DOM or
 * a Dexie transaction.
 */

/**
 * One chip in the amount row. `value` is the literal log amount for the
 * three fixed/derived chips; the trailing "#" (custom) chip carries `null`
 * — its actual amount comes from the user's typed input, tracked
 * separately by the caller.
 */
export interface AmountChipOption {
  value: number | null;
  label: string;
}

/**
 * The Counter Detail Log card's chip row — thin wrapper over the shared
 * `hubChips` (`logAmounts.ts`). Discrete: `1 · 10 · 25 · #`.
 *
 * @param kind - The counter's kind (default Discrete).
 * @returns The chips, ending in the custom `#`.
 */
export function buildAmountChipOptions(kind: CountKind = 'discrete'): AmountChipOption[] {
  return hubChips(kind);
}

/**
 * The board-play square's chip row — thin wrapper over the shared
 * `boardSheetChips`. Discrete: `+1 · +10 · #`; otherwise ¼ · ½ · goal · #.
 *
 * @param kind - The counter's kind (default Discrete).
 * @param goal - The square's goal (ignored for Discrete).
 * @returns The chips, ending in the custom `#`.
 */
export function buildBoardQuickAmountOptions(kind: CountKind = 'discrete', goal = 0): AmountChipOption[] {
  return boardSheetChips(kind, goal);
}

/** The fixed Discrete preset amounts (excludes the custom "#"). */
export const PRESET_LOG_AMOUNTS = [1, 10, 25] as const;

/**
 * The Discrete chip to pre-select when a picker opens: the remembered
 * `defaultLogAmount` when it is a preset, otherwise `1`. (Continuous /
 * Duration use the shared `initialLogSelection`.)
 *
 * @param defaultLogAmount - The counter's remembered default.
 * @returns The amount to pre-select.
 */
export function initialChipAmount(defaultLogAmount: number | null | undefined): number {
  return defaultLogAmount != null && (PRESET_LOG_AMOUNTS as readonly number[]).includes(defaultLogAmount)
    ? defaultLogAmount
    : 1;
}

/**
 * Parses a raw custom-amount string at the kind (Discrete: a positive
 * integer; Continuous: up to 2 dp with `.` or `,`; Duration: minutes or
 * `1h 30m`). Delegates to the shared `parseCountInput`.
 *
 * @param raw - The custom-input field's text.
 * @param kind - The counter's kind (default Discrete).
 * @returns The positive amount, or `null`.
 */
export function parseCustomLogAmount(raw: string, kind: CountKind = 'discrete'): number | null {
  return parseCountInput(raw, kind);
}
