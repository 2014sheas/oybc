/**
 * Pure copy builder for `CounterLogToast` (R2 Hub/Detail + R3 board-play
 * credited variant). Extracted from the component so the exact copy-contract
 * strings are unit-testable without a DOM (this repo's Vitest harness is
 * `environment: 'node'`, `*.test.ts` only — see `apps/web/vitest.config.ts`).
 */

import { countUnitSuffix, formatCount, type CountKind } from '@oybc/shared';

export interface CounterLogToastTextInput {
  /** Amount just logged (always positive — see `verb`). */
  amount: number;
  /** The counter's unit noun — used by the standalone copy only. */
  unit: string;
  /** `'logged'` for an increment, `'removed'` for a decrement. */
  verb: 'logged' | 'removed';
  /** The counter's pair-derived display name — required for the credited copy. */
  counterName?: string;
  /** Other boards this log also applied to — drives the credited copy when non-empty. */
  boardNames?: string[];
  /** The counter's kind (default Discrete) — formats the amount; Duration carries no unit. */
  kind?: CountKind;
}

/**
 * Builds the toast's display text.
 *
 * Copy contract (Counters Refresh R3 — pinned byte-exact, web ↔ iOS):
 *   credited increment: "+{N} {counterName}"
 *   credited decrement: "−{N} {counterName}"
 *   (`boardNames` only selects the credited variant; the names are not shown —
 *   which boards were credited is provenance the UI does not narrate)
 *
 * Falls back to the R2 standalone copy ("Logged +{N} {unit}" / "Removed {N}
 * {unit}") when `boardNames` is absent or empty — the Hub/Detail Log card's
 * existing contract, untouched by R3.
 */
export function formatCounterLogToastText(input: CounterLogToastTextInput): string {
  const { amount, unit, verb, counterName, boardNames, kind = 'discrete' } = input;
  const amountText = formatCount(amount, kind);

  if (boardNames != null && boardNames.length > 0) {
    const sign = verb === 'logged' ? '+' : '−';
    return `${sign}${amountText} ${counterName ?? ''}`.trimEnd();
  }
  const withUnit = `${amountText}${countUnitSuffix(kind, unit)}`;
  return verb === 'logged' ? `Logged +${withUnit}` : `Removed ${withUnit}`;
}
