/**
 * Pure copy builder for `CounterLogToast` (R2 Hub/Detail + R3 board-play
 * credited variant). Extracted from the component so the exact copy-contract
 * strings are unit-testable without a DOM (this repo's Vitest harness is
 * `environment: 'node'`, `*.test.ts` only — see `apps/web/vitest.config.ts`).
 */

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
}

/**
 * Builds the toast's display text.
 *
 * Copy contract (Counters Refresh R3 — pinned byte-exact, web ↔ iOS):
 *   credited increment: "+{N} {counterName} — also counted on {board list}."
 *   credited decrement: "−{N} {counterName} — also removed from {board list}."
 *   (board list = a plain comma-join of `boardNames`, unchanged from the
 *   retired `RisoCreditedToast`)
 *
 * Falls back to the R2 standalone copy ("Logged +{N} {unit}" / "Removed {N}
 * {unit}") when `boardNames` is absent or empty — the Hub/Detail Log card's
 * existing contract, untouched by R3.
 */
export function formatCounterLogToastText(input: CounterLogToastTextInput): string {
  const { amount, unit, verb, counterName, boardNames } = input;
  const hasCredit = boardNames != null && boardNames.length > 0;

  if (hasCredit) {
    const sign = verb === 'logged' ? '+' : '−';
    const verbPhrase = verb === 'logged' ? 'also counted on' : 'also removed from';
    return `${sign}${amount} ${counterName ?? ''} — ${verbPhrase} ${(boardNames as string[]).join(', ')}.`;
  }
  return verb === 'logged' ? `Logged +${amount} ${unit}` : `Removed ${amount} ${unit}`;
}
