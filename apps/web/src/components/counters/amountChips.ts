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
 * Builds the fixed four-chip row: `1`, the counter's current default
 * amount, `25`, and the custom "#" chip.
 *
 * `defaultAmount` is rendered verbatim even when it collides with `1` or
 * `25` (e.g. a fresh counter defaults to `1`) — the design's chip set is a
 * fixed four positions, not a deduped set; a collision just means two
 * chips show the same number, which is harmless (both log the same
 * amount).
 *
 * @param defaultAmount The counter's current default log amount (positive
 *   integer; callers pass `group.defaultLogAmount ?? 1`).
 */
export function buildAmountChipOptions(): AmountChipOption[] {
  // FIXED presets (owner decision, 2026-07-21): no dynamic "{default}" chip —
  // it collided with the fixed values (a fresh counter's default is 1) and
  // read as a bug on device. The per-counter default still drives the plain
  // board tap, the Hub "+ Log" pill, and what "#" persists; it just doesn't
  // get its own chip. Matches the handoff mock's literal "1 / 10 / 25 / #".
  return [
    { value: 1, label: '1' },
    { value: 10, label: '10' },
    { value: 25, label: '25' },
    { value: null, label: '#' },
  ];
}


/**
 * Builds the board-play square quick-action chip row (R3 — Counters Refresh
 * board-play touchpoints): `1`, the counter's current default amount, and
 * the custom "#" chip.
 *
 * Deliberately a 3-position row, unlike `buildAmountChipOptions`'s 4 (no
 * fixed `25` chip) — the handoff spec's board-square mock shows only
 * `1 / {default} / #` for the in-context quick actions on a shared counting
 * square's detail modal / context menu; the full `1 / {default} / 25 / #`
 * row stays exclusive to Counter Detail's Log card.
 *
 * @param defaultAmount The counter's current default log amount (positive
 *   integer; callers pass the source task's `defaultLogAmount ?? 1`).
 */
export function buildBoardQuickAmountOptions(): AmountChipOption[] {
  // FIXED signed presets (owner decision, 2026-07-21) — see
  // buildAmountChipOptions; board row stays 3-position (no 25).
  return [
    { value: 1, label: '+1' },
    { value: 10, label: '+10' },
    { value: null, label: '#' },
  ];
}

/** The fixed preset amounts backing both chip rows (excludes the custom "#"). */
export const PRESET_LOG_AMOUNTS = [1, 10, 25] as const;

/**
 * The chip to pre-select when a picker opens: the counter's remembered
 * `defaultLogAmount` when it happens to be a preset (so a habitual amount is
 * one tap away), otherwise `10` — the fixed rows have no dynamic chip to
 * carry an off-preset default, and a non-preset initial value would leave no
 * chip highlighted. (The remembered default still drives the one-tap board
 * paths — plain tap, Hub "+ Log" pill — independent of this.)
 */
export function initialChipAmount(defaultLogAmount: number | null | undefined): number {
  return defaultLogAmount != null && (PRESET_LOG_AMOUNTS as readonly number[]).includes(defaultLogAmount)
    ? defaultLogAmount
    : 10;
}

/**
 * Validates a raw custom-amount input string into a positive integer, or
 * `null` when the input isn't one (empty, non-numeric, zero, negative,
 * fractional, or leading/trailing junk).
 *
 * Intentionally strict (`^\d+$` on the trimmed string) — no leading `+`/`-`,
 * no decimal point, no scientific notation, no whitespace mid-string.
 *
 * @param raw The custom-input field's current text value.
 */
export function parseCustomLogAmount(raw: string): number | null {
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n <= 0) return null;
  return n;
}
